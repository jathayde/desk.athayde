require "rails_helper"

RSpec.describe OrderProposal, "sweeps" do
  let(:account) { create(:account) }

  def submitting(shadow:, age:)
    OrderProposal.create!(account: account, instrument: create(:instrument), kind: :entry, origin: :human, side: :buy, status: "submitting", shadow: shadow, quantity: 1, limit_price: 1, updated_at: age.ago).tap do |p|
      p.submission_attempts.create!(attempted_at: age.ago, outcome: :pending, payload: {})
    end
  end

  def unknown(looked_at:, attempted: 20.minutes.ago)
    OrderProposal.create!(account: account, instrument: create(:instrument), kind: :entry, origin: :human, side: :buy, status: "submission_unknown", quantity: 1, limit_price: 1).tap do |p|
      p.submission_attempts.create!(attempted_at: attempted, outcome: :unknown, last_looked_at: looked_at)
    end
  end

  it "finishes a stale shadow row as what it was going to be, sends a stale real row to reconciliation, and leaves a fresh one alone" do
    shadow = submitting(shadow: true, age: 6.minutes)
    real = submitting(shadow: false, age: 6.minutes)
    fresh = submitting(shadow: false, age: 30.seconds)
    expect { OrderProposal.sweep_submitting! }.to have_enqueued_job(Submission::ReconcileJob).with(real)
    expect(shadow.reload).to be_submitted
    expect(shadow.submission_attempts.sole).to be_would_have_submitted
    expect(real.reload).to be_submission_unknown
    expect(real.submission_attempts.sole.error).to eq("left submitting")
    expect(fresh.reload).to be_submitting
  end

  it "re-drives an unknown row nobody has looked at in a while, whether the last look was long ago or never happened" do
    stale = unknown(looked_at: 16.minutes.ago)
    never = unknown(looked_at: nil, attempted: 20.minutes.ago)
    recent = unknown(looked_at: 2.minutes.ago)
    young = unknown(looked_at: nil, attempted: 2.minutes.ago)
    expect { OrderProposal.redrive_unknown! }.to have_enqueued_job(Submission::ReconcileJob).with(stale).once.and have_enqueued_job(Submission::ReconcileJob).with(never).once
    expect(Submission::ReconcileJob).not_to have_been_enqueued.with(recent)
    expect(Submission::ReconcileJob).not_to have_been_enqueued.with(young)
  end
end
