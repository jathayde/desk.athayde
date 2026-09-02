require "rails_helper"

RSpec.describe Submission::ReconcileJob do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:fake) { Schwab::FakeClient.instance }

  before { ready_desk(account, settled: 6000); SystemSettings.instance.update!(shadow_mode: false) }

  def unknown_proposal
    fake.enqueue(:place_order) { raise Schwab::UnknownOutcome.new("Net::ReadTimeout", attempts: 1) }
    Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :human, user: john).tap do |p|
      p.approve_and_submit!(user: john, acknowledged: %w[ max_sector_exposure earnings_blackout ])
    end.reload
  end

  it "links the one order the timed-out call did place, after a fresh orders sync" do
    proposal = unknown_proposal
    fake.place!(proposal.submission_attempts.sole.payload, id: "777") # Schwab had it all along
    described_class.perform_now(proposal)
    expect(proposal.reload).to have_attributes(status: "submitted", broker_order_id: "777")
    expect(account.orders.find_by(broker_order_id: "777")).to have_attributes(order_proposal: proposal, placed_via: "app")
    expect(AuditEvent.where(subject: proposal, kind: "submission_reconciled")).to exist
  end

  it "counts a look that could not see for nothing: a failed sync is not an absence" do
    proposal = unknown_proposal
    attempt = proposal.submission_attempts.sole
    fake.enqueue(:orders, sticky: true) { raise Schwab::ServerError.new("down", status: 503) }
    expect { described_class.perform_now(proposal) }.to have_enqueued_job(described_class).with(proposal)
    expect(attempt.reload).to have_attributes(first_absence_at: nil, last_look_could_see: false)
    expect(attempt.last_looked_at).to be_present
    expect(proposal.reload).to be_submission_unknown
  end

  it "leaves two matches with the operator, and believes an absence only when a second look ten minutes later agrees" do
    proposal = unknown_proposal
    attempt = proposal.submission_attempts.sole
    2.times { |i| fake.place!(attempt.payload, id: "80#{i}") }
    expect { described_class.perform_now(proposal) }.to have_enqueued_job(described_class).with(proposal) # look again after the gap
    expect(proposal.reload).to be_submission_unknown
    expect(proposal.ambiguous_orders).to match_array(%w[ 800 801 ])
    expect(attempt.reload.last_looked_at).to be_present # so the tick does not re-drive it every five minutes

    fake.reset! # Schwab now returns neither; the sync marks the two it knew as gone, and the search finds nothing
    account.orders.where(broker_order_id: %w[ 800 801 ]).update_all(status: "CANCELED")
    expect { described_class.perform_now(proposal) }.to have_enqueued_job(described_class).with(proposal)
    expect(proposal.reload).to be_submission_unknown
    expect(attempt.reload.first_absence_at).to be_present
    expect(attempt.ambiguous_order_ids).to eq([])
    travel described_class::CONFIRMATION_GAP + 1.minute
    described_class.perform_now(proposal)
    expect(proposal.reload).to be_submission_failed
    expect(attempt.reload).to be_not_placed
    expect(OrderProposal.instrument_locked?(xyz)).to be(false)
  end
end
