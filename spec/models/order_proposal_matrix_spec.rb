require "rails_helper"

# Every status times every transition: allowed only where docs/phase-2-state-table.md has a row.
RSpec.describe OrderProposal, "transition matrix" do
  let(:account) { create(:account) }
  let(:instrument) { create(:instrument) }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:report) { Guardrails::Report.new([]) }

  # action => { from state => to state }, straight from the table
  def self.allowed
    { evaluate: { "proposed" => "validated" }, reject: { "validated" => "rejected" }, expire: { "proposed" => "expired", "validated" => "expired" },
      start_submission: { "validated" => "submitting" }, record_shadow: { "submitting" => "submitted" }, record_submitted: { "submitting" => "submitted" },
      record_unknown: { "submitting" => "submission_unknown" }, record_rejected: { "submitting" => "submission_failed" },
      record_not_placed: { "submission_unknown" => "submission_failed" }, record_reconciled: { "submission_unknown" => "submitted" },
      record_broker_outcome: { "submitted" => "filled" } }
  end

  def proposal_in(status)
    OrderProposal.create!(account: account, instrument: instrument, kind: :entry, origin: :human, side: :buy, status: status).tap do |p|
      p.submission_attempts.create!(attempted_at: Time.current, outcome: :pending) if status.in?(%w[ submitting submission_unknown submitted ])
    end
  end

  def attempt_of(proposal) = proposal.submission_attempts.first || proposal.submission_attempts.create!(attempted_at: Time.current, outcome: :failed)

  def perform(action, proposal)
    case action
    when :evaluate then proposal.evaluate!(report)
    when :reject then proposal.reject!(user: john, reason: "no")
    when :expire then proposal.expire!
    when :start_submission then proposal.start_submission!(user: john, acknowledged: [], override_reason: nil, payload: {}, shadow: true)
    when :record_shadow then proposal.record_shadow!(attempt_of(proposal))
    when :record_submitted then proposal.record_submitted!(attempt_of(proposal), broker_order_id: "1")
    when :record_unknown then proposal.record_unknown!(attempt_of(proposal), error: "timeout")
    when :record_rejected then proposal.record_rejected!(attempt_of(proposal), error: "400")
    when :record_not_placed then proposal.record_not_placed!(attempt_of(proposal))
    when :record_reconciled then proposal.record_reconciled!(attempt_of(proposal), order: create(:order, account: account, instrument: instrument, broker_order_id: "9"))
    when :record_broker_outcome then proposal.record_broker_outcome!(:filled)
    end
  end

  OrderProposal.statuses.each_key do |status|
    allowed.each do |action, transitions|
      it "#{transitions.key?(status) ? 'allows' : 'refuses'} #{action} from #{status}" do
        proposal = proposal_in(status)
        if transitions.key?(status)
          expect { perform(action, proposal) }.not_to raise_error
          expect(proposal.reload.status).to eq(transitions[status])
        else
          expect { perform(action, proposal) }.to raise_error(OrderProposal::IllegalTransition)
          expect(proposal.reload.status).to eq(status)
          expect(AuditEvent.where(subject: proposal)).to be_empty
        end
      end
    end
  end

  it "refuses a broker outcome that is not filled or cancelled without touching the row" do
    proposal = proposal_in("submitted")
    expect { proposal.record_broker_outcome!(:validated) }.to raise_error(ArgumentError)
    expect(proposal.reload).to be_submitted
  end

  it "refuses a stale instance's guess: the row's state wins" do
    proposal = proposal_in("validated")
    stale = OrderProposal.find(proposal.id)
    proposal.reject!(user: john, reason: "first")
    expect { stale.start_submission!(user: john, acknowledged: [], override_reason: nil, payload: {}, shadow: true) }.to raise_error(OrderProposal::IllegalTransition)
    expect(AuditEvent.where(subject: proposal, kind: "proposal_approved")).to be_empty
    expect(proposal.submission_attempts).to be_empty
  end

  it "refuses a second live submission on the instrument, in words and in the database" do
    first = proposal_in("submitting")
    second = proposal_in("validated")
    expect { second.start_submission!(user: john, acknowledged: [], override_reason: nil, payload: {}, shadow: true) }.to raise_error(OrderProposal::IllegalTransition, /still unresolved/)
    expect(second.reload).to be_validated
    expect { proposal_in("submission_unknown") }.to raise_error(ActiveRecord::RecordNotUnique)
    first.record_shadow!(first.submission_attempts.first)
    expect { proposal_in("submitting") }.not_to raise_error
  end

  it "refuses an attempt that belongs to another proposal, and links a shadowed submission to the order placed by hand" do
    a = proposal_in("submitting")
    b = OrderProposal.create!(account: account, instrument: create(:instrument), kind: :entry, origin: :human, side: :buy, status: "submitting").tap { |p| p.submission_attempts.create!(attempted_at: Time.current, outcome: :pending) }
    expect { a.record_shadow!(b.submission_attempts.first) }.to raise_error(ArgumentError)
    a.record_shadow!(a.submission_attempts.first)
    expect(a.reload).to be_submitted
    a.update!(shadow: true)
    order = create(:order, account: account, instrument: instrument, broker_order_id: "77")
    a.link_shadow_order!(a.submission_attempts.first, order: order)
    expect(a.reload.broker_order_id).to eq("77")
    expect(a.submission_attempts.first.reconciled_order).to eq(order)
    expect(AuditEvent.where(subject: a, kind: "submission_reconciled")).to exist
  end
end
