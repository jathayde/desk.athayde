require "rails_helper"

RSpec.describe Submission::Place do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:acknowledged) { %w[ max_sector_exposure earnings_blackout ] }
  let(:fake) { Schwab::FakeClient.instance }

  before { ready_desk(account, settled: 6000); SystemSettings.instance.update!(shadow_mode: false) }

  def approve(kind: :entry, quantity: nil, limit: 50)
    proposal = Proposals::Create.call(account: account, kind: kind, side: kind == :entry ? :buy : :sell, symbol: "XYZ", limit_price: limit, stop_price: kind == :entry ? 47 : nil,
                                      thesis: "t", origin: :human, user: john, quantity: quantity)
    proposal.approve_and_submit!(user: john, acknowledged: kind == :entry ? acknowledged : [])
    proposal.reload
  end

  it "places the bracket, records the broker id, and the next orders sync links the order and its child stop" do
    proposal = approve
    expect(proposal).to have_attributes(status: "submitted", shadow: false)
    expect(proposal.broker_order_id).to eq(fake.placed.first["orderId"].to_s)
    expect(proposal.submission_attempts.sole).to have_attributes(outcome: "submitted", broker_order_id: proposal.broker_order_id)
    Sync::OrdersJob.perform_now(account)
    order = account.orders.find_by(broker_order_id: proposal.broker_order_id)
    expect(order).to have_attributes(order_proposal: proposal, placed_via: "app", status: "WORKING")
    expect(order.child_orders.sole.order_type).to eq("STOP")
  end

  it "records a 4xx as rejected by Schwab with the error, the row terminal and the instrument free" do
    fake.enqueue(:place_order) { raise Schwab::RequestError.new("Schwab responded 400: quantity invalid", status: 400) }
    proposal = approve
    expect(proposal).to be_submission_failed
    expect(proposal.submission_attempts.sole).to have_attributes(outcome: "failed", response: { "error" => "order not sent: Schwab responded 400: quantity invalid" })
    expect(OrderProposal.instrument_locked?(xyz)).to be(false)
  end

  it "records a timeout after send as unknown, mails the operator, and hands the proposal to the reconcile job after the quiet period" do
    fake.enqueue(:place_order) { raise Schwab::UnknownOutcome.new("Net::ReadTimeout", attempts: 1) }
    expect { approve }.to have_enqueued_job(Submission::ReconcileJob).at(a_value_within(5.seconds).of(Submission::ReconcileJob::QUIET_PERIOD.from_now))
      .and have_enqueued_mail(AlertMailer, :submission_unknown)
    proposal = OrderProposal.last
    expect(proposal).to be_submission_unknown
    expect(OrderProposal.instrument_locked?(xyz)).to be(true)
    expect(proposal.submission_attempts.sole).to have_attributes(outcome: "unknown", response: { "error" => "UnknownOutcome: Net::ReadTimeout" })
  end

  it "cancels the working stop before a full exit and shrinks it before a partial one, audited, and does not sell when the stop cannot be adjusted" do
    stop = create(:order, :working_stop, account: account, instrument: xyz, quantity: 40, remaining_quantity: 40, stop_price: 47, broker_order_id: "stop-1")
    create(:position, account: account, instrument: xyz, quantity: 40, last_price: 50, market_value: 2000, working_stop_order: stop)
    account.reload
    partial = approve(kind: :exit, quantity: 10, limit: 55)
    expect(partial).to have_attributes(status: "submitted", child_action: "replace_stop")
    expect(fake.calls.map(&:first)).to include(:replace_order, :place_order)
    expect(AuditEvent.where(subject: partial, kind: "stop_adjusted").sole).to have_attributes(reason: "stop shrunk")
    expect(AuditEvent.where(subject: partial, kind: "stop_adjusted").sole.data["replacement_order"]).to be_present

    partial.record_broker_outcome!(:filled)
    fake.enqueue(:cancel_order) { raise Schwab::RequestError.new("Schwab responded 404: order not found", status: 404) }
    full = approve(kind: :exit, quantity: 40, limit: 55)
    expect(full).to be_submission_failed
    expect(full.submission_attempts.sole.response["error"]).to include("the stop could not be adjusted", "order not sent")
    expect(fake.calls.map(&:first).last).to eq(:cancel_order) # the sell never went in

    fake.enqueue(:cancel_order) { raise Schwab::UnknownOutcome.new("Net::ReadTimeout", attempts: 1) }
    quiet = approve(kind: :exit, quantity: 40, limit: 55)
    expect(quiet).to be_submission_failed # a stop step that went quiet is not a sell to reconcile
    expect(quiet.submission_attempts.sole.response["error"]).to include("got no answer", "check the stop at Schwab")
    expect(OrderProposal.instrument_locked?(xyz)).to be(false)
  end

  it "does not send when the sweep moved the row before the call, and keeps a 4xx that lands after the sweep as final" do
    proposal = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :human, user: john)
    attempt = proposal.start_submission!(user: john, acknowledged: acknowledged, override_reason: nil, payload: {}, shadow: false)
    proposal.record_unknown!(attempt, error: "left submitting") # the sweep got there first
    described_class.call(proposal, attempt)
    expect(fake.placed).to be_empty
    expect(proposal.reload).to be_submission_unknown
    expect(AuditEvent.where(subject: proposal, kind: "submission_skipped")).to exist

    fake.enqueue(:place_order) do |*|
      OrderProposal.last.then { |p| p.record_unknown!(p.submission_attempts.sole, error: "left submitting") } # swept mid-call
      raise Schwab::RequestError.new("Schwab responded 400: quantity invalid", status: 400)
    end
    proposal.record_rejected!(attempt, error: "cleared") # free the instrument for the next one
    late = approve
    expect(late).to be_submission_failed
    expect(late.submission_attempts.sole).to have_attributes(outcome: "failed", response: { "error" => "order not sent: Schwab responded 400: quantity invalid" })
  end

  it "puts a late id onto a row the reconcile job had called not placed, mails the operator, and the sync links the order" do
    proposal = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :human, user: john)
    attempt = proposal.start_submission!(user: john, acknowledged: acknowledged, override_reason: nil, payload: Schwab::OrderPayload.bracket(symbol: "XYZ", quantity: 33, limit_price: 50, stop_price: 47), shadow: false)
    proposal.record_unknown!(attempt, error: "Net::ReadTimeout")
    proposal.record_not_placed!(attempt.reload)
    expect(proposal.reload).to be_submission_failed
    id = fake.place!(attempt.payload) # Schwab had accepted it after all
    expect { proposal.record_submitted!(attempt.reload, broker_order_id: id) }.to have_enqueued_mail(AlertMailer, :late_submission)
    expect(proposal.reload).to have_attributes(status: "submitted", broker_order_id: id)
    expect(attempt.reload).to have_attributes(outcome: "submitted", broker_order_id: id)
    expect(AuditEvent.where(subject: proposal, kind: "proposal_submitted").sole.data).to include("late" => true)
    Sync::OrdersJob.perform_now(account)
    expect(account.orders.find_by(broker_order_id: id)).to have_attributes(order_proposal: proposal, placed_via: "app")
    expect { proposal.record_submitted!(attempt.reload, broker_order_id: id) }.to raise_error(OrderProposal::IllegalTransition) # once
  end

  it "rejects, as not sent, what certainly never reached Schwab: a rate limit, an auth failure, no token" do
    fake.enqueue(:place_order) { raise Schwab::RateLimited.new("busy", retry_after: 30) }
    expect(approve).to be_submission_failed
    expect(OrderProposal.last.submission_attempts.sole.response["error"]).to include("order not sent")
    SchwabToken.current.update!(revoked_at: Time.current)
    proposal = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :human, user: john)
    allow(Schwab).to receive(:client).and_raise(Schwab::NoUsableToken, "no usable Schwab token")
    proposal.approve_and_submit!(user: john, acknowledged: acknowledged)
    expect(proposal.reload).to be_submission_failed
  end
end
