require "rails_helper"

RSpec.describe Submission::Submit do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com", approver: false) }
  let(:acknowledged) { %w[ max_sector_exposure earnings_blackout ] }

  before { ready_desk(account) }

  def propose(stop: 47) = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: stop, thesis: "t", origin: :human, user: john)

  it "approves as the submission: one transaction for the state and the attempt, then the shadow branch, with the bracket payload on the record" do
    proposal = propose
    proposal.approve_and_submit!(user: john, acknowledged: acknowledged)
    expect(proposal.reload).to have_attributes(status: "submitted", shadow: true, acknowledged_warnings: acknowledged, decided_by: john)
    attempt = proposal.submission_attempts.sole
    expect(attempt).to be_would_have_submitted
    expect(attempt.payload).to include("orderType" => "LIMIT", "orderStrategyType" => "TRIGGER", "price" => "50.00")
    expect(AuditEvent.where(subject: proposal, kind: "would_have_submitted").sole.data["payload"]).to eq(attempt.payload)
    expect(attempt.payload["orderLegCollection"].first).to include("instruction" => "BUY", "quantity" => 33)
    expect(attempt.payload["childOrderStrategies"].first).to include("orderType" => "STOP", "stopPrice" => "47.00", "duration" => "GOOD_TILL_CANCEL")
    expect(AuditEvent.where(subject: proposal).pluck(:kind).last(3)).to eq(%w[ proposal_approved proposal_submitting would_have_submitted ])
  end

  it "refuses the non-approver, the wrong state, a missing acknowledgement, a missing override reason, and a second approval" do
    proposal = propose
    expect { proposal.approve_and_submit!(user: whitney, acknowledged: acknowledged) }.to raise_error(Submission::Refused, /only the approver/)
    expect { proposal.approve_and_submit!(user: john) }.to raise_error(Submission::Refused, /acknowledge max sector exposure and earnings blackout/i)
    expect(proposal.reload).to be_validated
    expect(proposal.submission_attempts).to be_empty
    proposal.reject!(user: john, reason: "make room") # one undecided proposal per instrument and side
    outside = propose(stop: 30)
    expect { outside.approve_and_submit!(user: john, acknowledged: acknowledged + [ "stop_collar" ]) }.to raise_error(Submission::Refused, /override reason/)
    outside.approve_and_submit!(user: john, acknowledged: acknowledged + [ "stop_collar" ], override_reason: "wide stop on purpose: news pending")
    expect(outside.reload).to have_attributes(status: "submitted", override_reason: "wide stop on purpose: news pending")
    expect { outside.approve_and_submit!(user: john, acknowledged: acknowledged) }.to raise_error(Submission::Refused, /not waiting for a decision/)
  end

  it "records every refusal on the row's audit trail, outside the rolled-back transaction" do
    proposal = propose
    expect { proposal.approve_and_submit!(user: whitney, acknowledged: acknowledged) }.to raise_error(Submission::Refused)
    expect(AuditEvent.where(subject: proposal, kind: "proposal_approval_refused").sole).to have_attributes(actor: "human", user: whitney, reason: "only the approver can approve")
    expect(proposal.reload).to be_validated
  end

  it "never lets a sell exceed the position, and refuses a sell of nothing before a row exists" do
    expect { Proposals::Create.call(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 55, thesis: "t", origin: :human, user: john) }.to raise_error(Proposals::Create::Refused, /Quantity can't be blank/)
    create(:position, account: account, instrument: xyz, quantity: 40, last_price: 50, market_value: 2000)
    account.reload
    too_many = Proposals::Create.call(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 55, thesis: "t", origin: :agent, quantity: 9999)
    expect(too_many).to be_rejected_by_rules
    expect(too_many.guardrail_results.dig("position_coverage", "detail")).to include("selling" => "9999.0", "held" => "40.0")
    all_of_it = Proposals::Create.call(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 55, thesis: "t", origin: :agent)
    expect(all_of_it).to have_attributes(status: "validated", quantity: 40)
    all_of_it.approve_and_submit!(user: john)
    expect(all_of_it.submission_attempts.sole.payload["orderLegCollection"].first).to include("instruction" => "SELL", "quantity" => 40)
  end

  it "counts an unfilled entry's cost against the exposure cap, so one name cannot carry two live orders" do
    first = propose
    first.approve_and_submit!(user: john, acknowledged: acknowledged)
    create(:balance, account: account, equity: 10_000, settled_cash: 6000, as_of: Time.current)
    second = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :agent)
    expect(second).to be_rejected_by_rules
    expect(second.guardrail_results.dig("max_position_exposure", "detail")).to include("committed" => "1650.0", "percent" => "33.0")
  end

  it "refuses when the desk changed since the proposal: a rule now blocks, or the sizing would differ" do
    proposal = propose
    create(:balance, account: account, equity: 10_000, settled_cash: 100, as_of: Time.current)
    expect { proposal.approve_and_submit!(user: john, acknowledged: acknowledged) }.to raise_error(Submission::Refused, /settled cash now block/)
    create(:balance, account: account, equity: 20_000, settled_cash: 3000, as_of: Time.current)
    expect { proposal.approve_and_submit!(user: john, acknowledged: acknowledged) }.to raise_error(Submission::Refused, /sizing would differ/)
    expect(proposal.reload).to be_validated

    create(:balance, account: account, equity: 10_000, settled_cash: 3000, as_of: Time.current)
    create(:trade, account: account, instrument: xyz, status: :closed, closed_at: 5.days.ago, realized_pnl: -80) # a wash-sale caution that was not there at creation
    expect { proposal.approve_and_submit!(user: john, acknowledged: acknowledged + [ "wash_sale" ]) }.to raise_error(Submission::Refused, /wash sale now warn; re-propose/)
  end

  it "engages the halt a fresh evaluation asks for, refuses under the halts, and refuses a real submission while that path is not built" do
    proposal = propose
    create(:trade, account: account, instrument: xyz, status: :closed, closed_at: Time.current, realized_pnl: -400)
    expect { proposal.approve_and_submit!(user: john, acknowledged: acknowledged) }.to raise_error(Submission::Refused, /daily loss halt now block/)
    expect(SystemSettings.instance).to be_rule_halted
    SystemSettings.instance.clear_rule_halt!(reason: "test")
    Trade.delete_all
    SystemSettings.instance.update!(shadow_mode: false)
    expect { proposal.approve_and_submit!(user: john, acknowledged: acknowledged) }.to raise_error(Submission::Refused, /not built yet/)
    expect(proposal.reload).to be_validated # refused before transaction one: the row is as it was
    expect(proposal.submission_attempts).to be_empty
  end
end
