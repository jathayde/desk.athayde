require "rails_helper"

RSpec.describe Research::SkepticJob do
  include ActiveJob::TestHelper

  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:fake) { Agent::FakeAnthropic.instance }

  before { ready_desk(account) }

  def propose(**) = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, target_price: 56, thesis: "range break", origin: :agent,
                                           forecast: { probability: 0.6, horizon_days: 10 }, **)

  it "is enqueued once an entry commits, and writes the case against it onto the proposal, never emailed" do
    proposal = nil
    expect { proposal = propose }.to have_enqueued_job(described_class)
    fake.enqueue(content: [ { type: :text, text: "The range break has no volume behind it, and an earnings date inside ten sessions is unknown.\nRisk: Timing" } ], stop_reason: :end_turn)
    expect { perform_enqueued_jobs }.not_to change(ActionMailer::Base.deliveries, :count)
    proposal.reload
    expect(proposal).to have_attributes(skeptic_note: "The range break has no volume behind it, and an earnings date inside ten sessions is unknown.", skeptic_risk: "timing")
    run = proposal.skeptic_run
    expect(run).to have_attributes(kind: "skeptic", status: "succeeded", order_proposal: proposal)
    expect(run.title).to start_with("skeptic note, XYZ")
    expect(AuditEvent.where(kind: "skeptic_note_written", subject: proposal).sole.data).to include("risk" => "timing")
    request = fake.requests.last
    expect(request[:system_]).to include("You are the skeptic")
    expect(request[:messages].first[:content]).to include('"XYZ": limit 50.0, stop 47.0, target 56.0', '"range break"', "The agent's forecast: 60.0%", "expected R before costs")
    expect(request[:system_]).to include("Do no arithmetic of your own", "Today is")
    expect(request[:tools].map { it[:name] }).to include("get_research_summary")
    expect(request[:tools].map { it[:name] }).not_to include("propose_order", "evaluate_hypothetical_order")
    described_class.perform_now(proposal) # never twice
    expect(proposal.skeptic_runs.count).to eq(1)
    expect { proposal.update_columns(skeptic_note: "softer") }.to raise_error(ActiveRecord::StatementInvalid, /frozen once written/)
  end

  it "names any objection outside the list as other, and runs for each entry the same day" do
    first = propose
    fake.enqueue(content: [ { type: :text, text: "It is fine, probably.\nRisk: vibes" } ], stop_reason: :end_turn)
    described_class.perform_now(first)
    expect(first.reload.skeptic_risk).to eq("other")
    first.reject!(user: john, reason: "no")
    second = propose(limit_price: 51)
    described_class.perform_now(second)
    expect(second.reload.skeptic_note).to be_present
  end

  it "writes a finished run's note it never wrote, rather than paying for another, and leaves no note from a bare risk line" do
    proposal = propose
    AgentRun.create!(kind: :skeptic, order_proposal: proposal, market_date: MarketDay.today, status: :succeeded, started_at: 1.minute.ago, finished_at: Time.current,
                     output_markdown: "Thin sample.\nRisk: sample")
    expect { described_class.perform_now(proposal) }.not_to change(fake.requests, :size)
    expect(proposal.reload).to have_attributes(skeptic_note: "Thin sample.", skeptic_risk: "sample")
    proposal.reject!(user: john, reason: "no")
    bare = propose(limit_price: 51)
    fake.enqueue(content: [ { type: :text, text: "Risk: cost" } ], stop_reason: :end_turn)
    described_class.perform_now(bare)
    expect(bare.reload.skeptic_note).to be_nil
  end

  it "stops at the day's cap with a line, and keeps a failed skeptic in the failure digest but not a capped one" do
    stub_const("#{described_class}::DAILY_CAP", 0)
    proposal = propose
    expect { described_class.perform_now(proposal) }.not_to change(fake.requests, :size)
    expect(proposal.skeptic_runs.sole).to have_attributes(status: "skipped", error: "the day's 0 skeptic notes are spent")
    capped = AgentRun.create!(kind: :skeptic, order_proposal: create(:order_proposal, account: account), market_date: MarketDay.today, status: :capped, started_at: 1.minute.ago, finished_at: Time.current)
    failed = AgentRun.create!(kind: :skeptic, order_proposal: create(:order_proposal, account: account), market_date: MarketDay.today, status: :failed, started_at: 1.minute.ago, finished_at: Time.current)
    expect(FailureDigest.new.agent_failures).to include(failed)
    expect(FailureDigest.new.agent_failures).not_to include(capped)
  end

  it "leaves a failed run as a line, and skips an entry the rules rejected" do
    proposal = propose
    fake.enqueue { raise Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com"), request: nil) }
    described_class.perform_now(proposal)
    expect(proposal.reload.skeptic_note).to be_nil
    expect(proposal.skeptic_runs.first).to be_failed
    fake.enqueue { raise Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com"), request: nil) }
    described_class.perform_now(proposal) # the one retry
    expect { described_class.perform_now(proposal) }.not_to change(AgentRun, :count) # and no more
    proposal.reject!(user: john, reason: "no")
    blocked = propose(stop_price: 30)
    OrderProposal.where(id: blocked).update_all(status: "rejected_by_rules")
    expect { described_class.perform_now(blocked.reload) }.not_to change(AgentRun, :count)
  end

  it "reads the stored research through a tool the briefs and the skeptic have and the proposing agent does not" do
    CalibrationSnapshot.create!(as_of: MarketDay.today, scope: "author", key: "agent", label: "Agent", figures: { "n" => 4 })
    result = Agent::Tools.call("get_research_summary", {}, transport: :scheduled)
    expect(result).to be_ok
    expect(result.value["calibration"].sole).to include("label" => "Agent", "verdict" => "not enough forecasts yet (4 scored; 20 needed)")
    expect(Agent::Tools.call("get_research_summary", {}, transport: :mcp).error).to include("not available")
  end
end
