require "rails_helper"

RSpec.describe Proposals::Create do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }

  before { ready_desk(account) }

  it "creates, evaluates, and audits a proposal in one go, sized and collared, expiring with the day" do
    proposal = described_class.call(account: account, kind: :entry, side: :buy, symbol: "xyz", limit_price: 50, stop_price: 47, thesis: "range break", origin: :human, user: john)
    expect(proposal).to have_attributes(status: "validated", quantity: 33, origin: "human", order_type: "LIMIT")
    expect(proposal.expires_at).to be_within(1.second).of(MarketDay.today.in_time_zone(MarketDay::ZONE).end_of_day)
    expect(AuditEvent.where(subject: proposal).pluck(:kind)).to eq(%w[ proposal_created proposal_evaluated ])
    expect(proposal.warnings).to match_array(%w[ max_sector_exposure earnings_blackout ])
    travel_to proposal.expires_at + 1.minute do
      Sync::TickJob.perform_now
      expect(proposal.reload).to be_expired
    end
  end

  it "keeps one undecided proposal per instrument and side, in words and in the database" do
    first = described_class.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :human, user: john)
    expect { described_class.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 51, stop_price: 48, thesis: "t", origin: :agent) }.to raise_error(described_class::Refused, /already has a buy proposal waiting \(##{first.id}\)/)
    expect { OrderProposal.create!(account: account, instrument: xyz, kind: :entry, origin: :agent, side: :buy, status: "validated") }.to raise_error(ActiveRecord::RecordNotUnique)
    first.reject!(user: john, reason: "no")
    expect(described_class.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 51, stop_price: 48, thesis: "t", origin: :agent)).to be_validated
  end

  it "refuses before any row exists during a rule halt (entries) and the kill switch (everything)" do
    SystemSettings.instance.trip_rule_halt!(rule: "daily_loss_halt", reason: "down", resets_at: 1.hour.from_now)
    expect { described_class.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, origin: :agent) }.to raise_error(described_class::Refused, /entries are halted/)
    create(:position, account: account, instrument: xyz, quantity: 40)
    expect(described_class.call(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 55, origin: :agent).quantity).to eq(40)
    SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: "stop")
    expect { described_class.call(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 55, origin: :agent) }.to raise_error(described_class::Refused, /halted/)
    expect(OrderProposal.count).to eq(1)
  end

  it "is the propose_order tool's only path: interactive transport, audited, never scheduled" do
    result = Agent::Tools.call("propose_order", { symbol: "xyz", side: "buy", limit_price: "50", stop_price: "47", target_price: "56", probability: 0.4, horizon_days: 10, thesis: "range break" }, transport: :mcp)
    expect(result.ok?).to be(true)
    expect(result.value).to include("status" => "validated", "quantity" => 33, "blocked" => false)
    proposal = OrderProposal.find(result.value["proposal_id"])
    expect(proposal).to have_attributes(origin: "agent", thesis: "range break", target_price: 56)
    expect(proposal.forecasts.sole).to have_attributes(author: "agent", probability: BigDecimal("0.4"), horizon_days: 10, entry_price: 50, stop_price: 47, target_price: 56, user: nil)
    expect(AuditEvent.where(kind: "agent_tool_used").last.data).to include("tool" => "propose_order", "ok" => true)
    expect(Agent::Tools.call("propose_order", { symbol: "xyz", side: "buy", limit_price: "50", thesis: "x" }, transport: :scheduled).error).to include("not available")
    SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: "stop")
    expect(Agent::Tools.call("propose_order", { symbol: "xyz", side: "buy", limit_price: "50", stop_price: "47", target_price: "56", probability: 0.4, horizon_days: 10, thesis: "x" }, transport: :mcp).error).to include("halted")
  end

  describe "the forecast an entry carries (docs/phase-2.6-plan.md §0.2)" do
    def propose(**extra) = Agent::Tools.call("propose_order", { symbol: "xyz", side: "buy", limit_price: "50", stop_price: "47", thesis: "t" }.merge(extra), transport: :mcp)

    it "is required of the agent on an entry, and not asked of an exit" do
      expect(propose.error).to include("an entry needs target_price, probability, and horizon_days")
      expect(propose(target_price: "56", probability: 0.4).error).to include("an entry needs horizon_days")
      create(:position, account: account, instrument: xyz, quantity: 40)
      expect(Agent::Tools.call("propose_order", { symbol: "xyz", side: "sell", limit_price: "55", thesis: "t" }, transport: :mcp)).to be_ok
      expect(Forecast.count).to eq(0)
    end

    it "is measured from the last final close, never today's partial bar, and refused when that close has already settled it" do
      proposal = described_class.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, target_price: 56, thesis: "t", origin: :human, user: john,
                                      forecast: { probability: "0.35", horizon_days: "15" })
      expect(proposal.reference_on).to eq(MarketDay.today - 1)
      expect(proposal.forecasts.sole).to have_attributes(author: "human", user: john, reference_close: proposal.reference_close, reference_on: MarketDay.today - 1, saw_agent_forecast: false)
      expect(AuditEvent.where(kind: "forecast_recorded").last.data).to include("proposal" => proposal.id, "probability" => "0.35", "horizon_days" => 15)
      proposal.reject!(user: john, reason: "no")
      expect(propose(target_price: "56", probability: 1, horizon_days: 10).error).to be_present # the schema's exclusive bound
      expect { described_class.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, target_price: 56, thesis: "t", origin: :agent, forecast: { probability: "0.4", horizon_days: "90" }) }
        .to raise_error(described_class::Refused, /forecast: horizon must be/) # the author's mistake refuses the proposal
      expect(OrderProposal.where(origin: "agent")).to be_empty
    end

    it "never decides what is proposed: levels the desk cannot measure leave the entry without a forecast, on the record" do
      result = propose(target_price: "50.5", probability: 0.4, horizon_days: 10)
      expect(result.value["forecast"]).to match(/not recorded: the last close .* is outside the stop and the target/)
      proposal = OrderProposal.find(result.value["proposal_id"])
      expect(proposal.forecasts).to be_empty
      expect(AuditEvent.where(kind: "forecast_not_recorded", subject: proposal).sole.reason).to include("outside the stop and the target")
      create(:position, account: account, instrument: xyz, quantity: 40)
      expect(Agent::Tools.call("propose_order", { symbol: "xyz", side: "sell", limit_price: "55", thesis: "t" }, transport: :mcp).value).to include("forecast" => nil)
    end
  end
end
