require "rails_helper"

# The transition table in docs/phase-2-state-table.md, row by row.
RSpec.describe OrderProposal do
  let(:account) { create(:account) }
  let(:instrument) { create(:instrument, symbol: "XYZ") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:proposal) { described_class.create!(account: account, instrument: instrument, kind: :entry, origin: :human, user: john, side: :buy, quantity: 10, limit_price: 50, stop_price: 48) }

  def result(type, outcome, **rest) = Guardrails::Result.new(rule_type: type, outcome: outcome, detail: {}, version: 1, params: {}, **rest)
  def report(*results) = Guardrails::Report.new(results)
  def audits = AuditEvent.where(subject: proposal).order(:id).pluck(:kind)

  it "validates on an evaluation without a hard fail and rejects on one, snapshotting the results" do
    proposal.evaluate!(report(result("settled_cash", :pass), result("wash_sale", :caution)))
    expect(proposal).to be_validated
    expect(proposal.warnings).to eq([ "wash_sale" ])
    proposal.update!(guardrail_results: proposal.guardrail_results.merge("earnings_blackout" => { "outcome" => "unavailable" }))
    expect(proposal.warnings).to eq(%w[ wash_sale earnings_blackout ]) # what could not be checked is acknowledged too
    expect(proposal.guardrail_results.dig("settled_cash", "outcome")).to eq("pass")

    other = described_class.create!(account: account, instrument: create(:instrument), kind: :entry, origin: :agent, side: :buy)
    other.evaluate!(report(result("settled_cash", :block)))
    expect(other).to be_rejected_by_rules
    expect(other).to be_rejected_by_rules
    expect { other.evaluate!(report) }.to raise_error(OrderProposal::IllegalTransition)
  end

  it "engages the halt a report asks for in the same transaction as the evaluation" do
    proposal.evaluate!(report(result("daily_loss_halt", :block, trip: { rule: "daily_loss_halt", reason: "down 4% today", resets_at: 1.hour.from_now })))
    expect(proposal).to be_rejected_by_rules
    expect(SystemSettings.instance).to be_rule_halted
    expect(SystemSettings.instance.rule_halt_rule).to eq("daily_loss_halt")
  end

  it "rejects only with a reason, expires only while undecided, and refuses to expire a submission" do
    proposal.evaluate!(report)
    expect { proposal.reject!(user: john, reason: "") }.to raise_error(ArgumentError)
    proposal.reject!(user: john, reason: "not today")
    expect(proposal).to have_attributes(status: "rejected", rejection_reason: "not today", decided_by: john)
    expect { proposal.expire! }.to raise_error(OrderProposal::IllegalTransition)

    fresh = described_class.create!(account: account, instrument: instrument, kind: :entry, origin: :agent, side: :buy, expires_at: 1.minute.ago)
    expect(described_class.expiring).to include(fresh)
    fresh.expire!
    expect(fresh).to be_expired
  end

  it "walks approve into submitting with one live attempt, then submitted with the broker id, and locks the instrument meanwhile" do
    proposal.evaluate!(report(result("wash_sale", :caution)))
    attempt = proposal.start_submission!(user: john, acknowledged: [ "wash_sale" ], override_reason: nil, payload: { "orderType" => "LIMIT" }, shadow: false)
    expect(proposal).to be_submitting
    expect(described_class.instrument_locked?(instrument)).to be(true)
    expect { proposal.submission_attempts.create!(attempted_at: Time.current, outcome: :pending) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { proposal.reject!(user: john, reason: "late") }.to raise_error(OrderProposal::IllegalTransition)

    proposal.record_submitted!(attempt, broker_order_id: "100")
    expect(proposal).to have_attributes(status: "submitted", broker_order_id: "100")
    expect(attempt.reload).to have_attributes(outcome: "submitted", broker_order_id: "100")
    expect(described_class.instrument_locked?(instrument)).to be(false)
    proposal.record_broker_outcome!(:filled)
    expect(audits).to eq(%w[ proposal_evaluated proposal_approved proposal_submitting proposal_submitted proposal_filled ])
  end

  it "records a shadow submission as submitted with a would_have_submitted attempt" do
    proposal.evaluate!(report)
    attempt = proposal.start_submission!(user: john, acknowledged: [], override_reason: nil, payload: {}, shadow: true)
    proposal.record_shadow!(attempt)
    expect(proposal).to have_attributes(status: "submitted", shadow: true)
    expect(attempt.reload).to be_would_have_submitted
    expect(audits.last).to eq("would_have_submitted")
  end

  it "goes unknown on an ambiguous outcome and can only be reconciled forward or failed, never back to validated" do
    proposal.evaluate!(report)
    attempt = proposal.start_submission!(user: john, acknowledged: [], override_reason: nil, payload: {}, shadow: false)
    proposal.record_unknown!(attempt, error: "Net::ReadTimeout")
    expect(proposal).to be_submission_unknown
    expect(described_class.instrument_locked?(instrument)).to be(true)
    expect { proposal.expire! }.to raise_error(OrderProposal::IllegalTransition)
    proposal.record_not_placed!(attempt)
    expect(proposal).to be_submission_failed
    expect(attempt.reload).to be_not_placed
    expect(described_class.instrument_locked?(instrument)).to be(false)
    expect(audits.last(2)).to eq(%w[ submission_unknown submission_failed ])
  end

  it "fails a 4xx and lets a second proposal on the instrument be created afterwards" do
    proposal.evaluate!(report)
    attempt = proposal.start_submission!(user: john, acknowledged: [], override_reason: nil, payload: {}, shadow: false)
    proposal.record_rejected!(attempt, error: "400 bad quantity")
    expect(proposal).to be_submission_failed
    expect(attempt.reload).to be_failed
    expect(proposal.live_attempt).to be_nil
  end
end
