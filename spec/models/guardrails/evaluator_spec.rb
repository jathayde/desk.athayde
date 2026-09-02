require "rails_helper"

RSpec.describe Guardrails::Evaluator do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }

  def seed_rules(**overrides)
    { "max_risk_per_trade" => { "percent" => "1.0" }, "max_positions" => { "count" => "3" }, "max_position_exposure" => { "percent" => "25" },
      "max_sector_exposure" => {}, "daily_loss_halt" => { "percent" => "3" }, "max_drawdown_halt" => { "percent" => "10" },
      "earnings_blackout" => {}, "wash_sale" => { "days" => "30" }, "notional_cap" => { "per_order" => "2500", "per_day" => "5000" },
      "stop_collar" => StopCollar::Calculator::DEFAULTS }.merge(overrides).each do |type, params|
      RiskRule.create!(rule_type: type, params: params, mode: type == "wash_sale" ? "warn" : "block")
    end
  end

  # reload: the has-one current_balance is cached on the spec's account object, unlike a request's fresh record
  def fresh_balance(settled: 3000, equity: 10_000, at: Time.current) = create(:balance, account: account, equity: equity, settled_cash: settled, as_of: at).tap { account.reload }
  def synced!(at: Time.current) = %w[ positions orders activities ].each { |f| create(:sync_run, feed: f, account: account, started_at: at, finished_at: at) }
  def entry(limit: 50, stop: 47, setup: nil) = Proposals.draft(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: limit, stop_price: stop, setup: setup, origin: :human, user: john)
  def exit_of(quantity: 10, limit: 55) = Proposals.draft(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: limit, origin: :human, quantity: quantity)
  def outcomes(report) = report.to_h.transform_values { |r| r["outcome"] }
  def ready = (seed_rules; fresh_balance; synced!)

  before { xyz; script_price_history; account.snapshots.create!(as_of: MarketDay.today - 1, equity: 10_000, drawdown: BigDecimal("0.02")) }

  it "passes a well-formed entry with the two unavailable rules to acknowledge, sized and collared, and skips what does not apply to an exit" do
    ready
    proposal = entry
    expect(proposal.quantity).to eq(33) # 1% of 10,000 = 100 over 3 per share
    report = described_class.new(proposal).call
    expect(report).not_to be_blocked
    expect(report.warnings).to match_array(%w[ max_sector_exposure earnings_blackout ])
    expect(outcomes(report)).to include("halt" => "pass", "settled_cash" => "pass", "stop_collar" => "pass", "notional_cap" => "pass", "wash_sale" => "pass", "max_risk_per_trade" => "pass")
    expect(report.to_h.dig("settled_cash", "detail", "projected_settled_cash")).to eq("3000.0")
    expect(outcomes(described_class.new(exit_of).call)).to include("settled_cash" => "skipped", "notional_cap" => "skipped", "stop_collar" => "skipped", "max_risk_per_trade" => "skipped")
  end

  it "blocks settled cash when the balance is missing or stale, and when pending buys and the broker's other buys already claim it" do
    seed_rules
    expect(outcomes(described_class.new(entry).call)["settled_cash"]).to eq("block") # no balance at all
    fresh_balance(at: 3.hours.ago)
    synced!(at: 3.hours.ago)
    expect(described_class.new(entry).call.to_h.dig("settled_cash", "detail", "reason")).to include("stale")
    fresh_balance(settled: 3000)
    synced!
    create(:order, account: account, instrument: create(:instrument), status: "WORKING", side: "BUY", order_type: "LIMIT", quantity: 10, remaining_quantity: 10, limit_price: 100)
    app_order = create(:order, account: account, instrument: create(:instrument), status: "WORKING", side: "BUY", order_type: "LIMIT", quantity: 10, remaining_quantity: 10, limit_price: 100)
    submitted = OrderProposal.create!(account: account, instrument: app_order.instrument, kind: :entry, origin: :human, side: :buy, status: "submitted", quantity: 10, limit_price: 50)
    app_order.update!(order_proposal: submitted) # the app's own resting order counts once, as the proposal
    report = described_class.new(entry).call
    expect(report.to_h.dig("settled_cash", "detail")).to include("projected_settled_cash" => "1500.0", "cost" => "1650.0")
    expect(outcomes(report)["settled_cash"]).to eq("block")
  end

  it "blocks the hard rules and marks the rest unavailable when no rule row exists, and marks a malformed row unavailable" do
    fresh_balance
    synced!
    report = described_class.new(entry).call
    expect(outcomes(report)).to include("settled_cash" => "pass", "max_risk_per_trade" => "block", "notional_cap" => "block", "stop_collar" => "block", "wash_sale" => "unavailable", "daily_loss_halt" => "unavailable")
    expect(report).to be_blocked
    RiskRule.create!(rule_type: "max_positions", params: { "count" => "3" }).update_column(:params, {})
    expect(described_class.new(entry).call.to_h["max_positions"]).to include("outcome" => "unavailable", "detail" => { "reason" => "max_positions rule has no count" })
  end

  it "blocks rule 1 when equity has fallen since the sizing, and blocks the count and exposure caps" do
    ready
    proposal = entry
    fresh_balance(equity: 2000)
    result = described_class.new(proposal).call.to_h["max_risk_per_trade"]
    expect(result).to include("outcome" => "block")
    expect(result["detail"]).to include("at_risk" => "99.0", "budget" => "20.0", "frozen_budget" => "100.0")

    fresh_balance(equity: 10_000)
    3.times { create(:position, account: account, instrument: create(:instrument)) }
    expect(outcomes(described_class.new(entry).call)["max_positions"]).to eq("block")
    OrderProposal.create!(account: account, instrument: create(:instrument), kind: :entry, origin: :human, side: :buy, status: "validated", quantity: 1, limit_price: 1)
    Position.delete_all
    expect(described_class.new(entry).call.to_h.dig("max_positions", "detail")).to include("pending" => 1)
    create(:position, account: account, instrument: xyz, quantity: 40, market_value: 2000, last_price: 50)
    expect(outcomes(described_class.new(entry).call)["max_position_exposure"]).to eq("block") # 2000 + 1650 = 36.5% of 10,000
  end

  it "asks for a halt from a loss or a drawdown but writes nothing itself; the writer engages it, and exits stay open" do
    ready
    create(:trade, account: account, instrument: xyz, status: :closed, closed_at: Time.current, realized_pnl: -400)
    report = described_class.new(entry).call
    expect(outcomes(report)["daily_loss_halt"]).to eq("block")
    expect(report.trips.map { |t| t[:rule] }).to eq([ "daily_loss_halt" ])
    expect(SystemSettings.instance).not_to be_rule_halted
    Guardrails.engage_halts!(report)
    expect(SystemSettings.instance).to be_rule_halted
    expect(outcomes(described_class.new(entry).call)["halt"]).to eq("block")
    expect(outcomes(described_class.new(exit_of).call)["halt"]).to eq("pass")
    SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: "stop")
    expect(outcomes(described_class.new(exit_of).call)["halt"]).to eq("block")

    account.snapshots.create!(as_of: MarketDay.today, equity: 8000, drawdown: BigDecimal("0.2"))
    drawdown = described_class.new(entry).call
    expect(outcomes(drawdown)["max_drawdown_halt"]).to eq("block")
    expect(drawdown.trips.last).to include(rule: "max_drawdown_halt", resets_at: nil)
  end

  it "cautions on a stop outside the collar as the one overridable result, blocks a collar it could not compute, and admits the floor's span when it dominates" do
    ready
    report = described_class.new(entry(limit: 50, stop: 30)).call
    expect(report.to_h.dig("stop_collar", "outcome")).to eq("caution")
    expect(report).to be_needs_override
    Schwab::FakeClient.instance.reset!
    Rails.cache.clear # the good history is cached; a fresh calculator must see the shipped two-candle fixture
    broken = entry
    expect(broken.collar["refusal"]).to include("only 2 daily candles")
    expect(outcomes(described_class.new(broken).call)["stop_collar"]).to eq("block")
    Rails.cache.clear
    script_price_history(range: 6)
    dominated = entry(limit: 50, stop: 48)
    expect(dominated.collar["floor_dominates"]).to be(true)
    expect(outcomes(described_class.new(dominated).call)["stop_collar"]).to eq("pass") # inside [floor, entry)
  end

  it "cautions or blocks a buy after a recent taxable loss, and cautions a loss-realizing sell after a replacement buy in either account, not the sold lot" do
    ready
    create(:trade, account: account, instrument: xyz, status: :closed, closed_at: 5.days.ago, realized_pnl: -80)
    expect(outcomes(described_class.new(entry).call)["wash_sale"]).to eq("caution")
    RiskRule.active_for("wash_sale").supersede!(params: { "days" => "30" }, user: john, mode: "block")
    expect(outcomes(described_class.new(entry).call)["wash_sale"]).to eq("block")

    trade = create(:trade, account: account, instrument: xyz, status: :open, avg_entry: 60, quantity: 10)
    own = fill(account, xyz, "BUY", 10, 60, at: 4.days.ago)
    trade.trade_legs.create!(kind: :entry, quantity: 10, price: 60, cash_amount: -600, executed_at: 4.days.ago, activity: own)
    expect(outcomes(described_class.new(exit_of(limit: 55)).call)["wash_sale"]).to eq("pass") # the lot being sold is not a replacement
    ira = create(:account, account_type: "ira", trading_enabled: false, nickname: "IRA")
    create(:activity, account: ira, instrument: xyz, kind: "fill", side: "BUY", quantity: 5, price: 58, net_amount: -290, executed_at: 3.days.ago, trade_date: 3.days.ago.to_date, status: "VALID")
    result = described_class.new(exit_of(limit: 55)).call.to_h["wash_sale"]
    expect(result["outcome"]).to eq("caution")
    expect(result.dig("detail", "recent_buys").first["account"]).to eq("IRA")
  end

  it "caps notional per buy and per day, counting today's committed buys, and never an exit" do
    seed_rules("notional_cap" => { "per_order" => "1000", "per_day" => "1500" })
    fresh_balance(settled: 5000)
    synced!
    expect(outcomes(described_class.new(entry).call)["notional_cap"]).to eq("block") # 33 × 50 = 1650 > 1000
    OrderProposal.create!(account: account, instrument: create(:instrument), kind: :entry, origin: :human, side: :buy, status: "submission_unknown", quantity: 20, limit_price: 50, decided_at: Time.current)
    small = entry(limit: 10, stop: 9)
    expect(small.quantity).to eq(100)
    expect(outcomes(described_class.new(small).call)["notional_cap"]).to eq("block") # 1000 unknown today + 1000 > 1500
    expect(outcomes(described_class.new(exit_of(quantity: 500, limit: 100)).call)["notional_cap"]).to eq("skipped")
  end

  it "locks an instrument with an unresolved submission" do
    ready
    OrderProposal.create!(account: account, instrument: xyz, kind: :entry, origin: :human, side: :buy, status: "submission_unknown", quantity: 1, limit_price: 50)
    expect(outcomes(described_class.new(entry).call)["pending_reconciliation"]).to eq("block")
  end

  it "answers the hypothetical tool without writing a row, an audit event, or a halt, and sizes an exit from the position" do
    ready
    create(:trade, account: account, instrument: xyz, status: :closed, closed_at: Time.current, realized_pnl: -400)
    expect {
      result = Agent::Tools.call("evaluate_hypothetical_order", { symbol: "xyz", side: "buy", limit_price: "50", stop_price: "47" }, transport: :scheduled)
      expect(result.ok?).to be(true)
      expect(result.value).to include("blocked" => true, "quantity" => 33, "would_trip_halt" => [ "daily_loss_halt" ])
    }.not_to change { [ AuditEvent.count, OrderProposal.count, SystemSettings.instance.reload.rule_halt_tripped_at ] }
    create(:position, account: account, instrument: xyz, quantity: 40, market_value: 2000, last_price: 50)
    expect(Agent::Tools.call("evaluate_hypothetical_order", { symbol: "xyz", side: "sell", limit_price: "55" }, transport: :scheduled).value["quantity"]).to eq(40)
    expect(Agent::Tools.call("evaluate_hypothetical_order", { symbol: "NOPE", side: "buy", limit_price: "50" }, transport: :mcp).error).to include("unknown symbol")
    rules = Agent::Tools.call("get_risk_rules", {}, transport: :mcp).value
    expect(rules).to include("available" => true)
    expect(rules["rules"].size).to eq(10)
  end
end
