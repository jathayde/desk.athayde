require "rails_helper"

RSpec.describe ThesisReview do
  include ActiveJob::TestHelper

  let(:zone) { Time.find_zone!("America/New_York") }
  let(:wednesday) { zone.local(2026, 10, 14, 16) }
  let!(:token) { create(:schwab_token) }
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:tqqq) { create(:instrument, symbol: "TQQQ") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true, notify: true) }

  before do
    travel_to wednesday + 70.minutes
    seed_rule_set
    { "rebalance_band" => { "percent" => "5" }, "min_rebalance_notional" => { "amount" => "100" } }.each { |type, params| RiskRule.create!(rule_type: type, params: params) }
    create(:position, account: account, instrument: tqqq, quantity: 40, last_price: 53, market_value: 2120, average_price: 40, cost_basis: 1600)
    tqqq.classify!(asset_class: nil, tags: %w[ amplified ], user: john)
    synced_after_close(wednesday)
  end

  after { travel_back }

  def synced_after_close(closed_at)
    create(:balance, account: account, equity: 10_000, settled_cash: 3000, as_of: closed_at + 45.minutes)
    create(:sync_run, feed: "positions", account: account, started_at: closed_at + 50.minutes, finished_at: closed_at + 50.minutes)
  end

  def next_night(date)
    travel_to zone.local(date.year, date.month, date.day, 17, 10)
    synced_after_close(zone.local(date.year, date.month, date.day, 16))
    Allocation::DriftJob.perform_now
  end

  it "asks once with the journal's thesis and the numbers, alerts, refreshes the numbers the next night, and never proposes" do
    account.trades.create!(instrument: tqqq, status: :open, thesis: "Leveraged Nasdaq into the cut cycle.")
    target = Allocation::Target.add!(symbol: "TQQQ", target_percent: "10", user: john)
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) { Allocation::DriftJob.perform_now }
    review = described_class.sole
    expect(review).to have_attributes(reason: "drift", thesis: "Leveraged Nasdaq into the cut cycle.", decision: nil, side: "sell")
    expect(review.context).to include("weight" => "0.212", "target_weight" => "0.1", "close" => "53.0", "quantity" => "40.0", "unrealized_pnl" => "520.0")
    expect(target.drifts.sole).to have_attributes(action: "thesis_review", thesis_review: review)
    expect(AuditEvent.where(kind: "thesis_review_created").sole.data).to include("symbol" => "TQQQ")
    expect(ActionMailer::Base.deliveries.map(&:subject)).to include("Athayde Desk: TQQQ drifted: thesis review")

    Position.where(instrument: tqqq).update_all(market_value: 2300)
    next_night(Date.new(2026, 10, 15))
    expect(described_class.sole.context["weight"]).to eq("0.23")
    expect(target.drifts.order(:as_of).last.thesis_review).to eq(review)
    expect(OrderProposal.count).to eq(0)
  end

  it "says when there is no thesis, takes the watchlist's when there is no trade, and a hold stands while the drift stays on its side" do
    target = Allocation::Target.add!(symbol: "TQQQ", target_percent: "10", user: john)
    Allocation::DriftJob.perform_now
    expect(described_class.sole.thesis).to be_nil

    review = described_class.sole
    expect { review.decide!(decision: "hold", user: john) }.to raise_error(ArgumentError, "a hold needs a reason")
    review.decide!(decision: "hold", reason: "riding the trend", user: john)
    expect(AuditEvent.where(kind: "thesis_review_decided").sole).to have_attributes(reason: "riding the trend", data: hash_including("decision" => "hold"))
    expect { review.decide!(decision: "exit", user: john) }.to raise_error(ActiveRecord::StaleObjectError)

    next_night(Date.new(2026, 10, 15))
    expect(target.drifts.order(:as_of).last).to have_attributes(action: "rejected_standing", detail: hash_including("held" => true))
    expect(target.rejection_standing_now?).to be(true)

    WatchlistItem.watch!(symbol: "TQQQ", trigger: "on a pullback", thesis: "Watch for the cut.", origin: :human, user: john)
    target.clear_rejection!(user: john)
    next_night(Date.new(2026, 10, 16))
    expect(described_class.open.sole.thesis).to eq("Watch for the cut.")
  end

  it "steps aside for a proposal already waiting, asks again only once a deploy's proposal is gone, and keeps a rerun from raising twice" do
    target = Allocation::Target.add!(symbol: "TQQQ", target_percent: "10", user: john)
    Allocation::DriftJob.perform_now
    review = described_class.sole
    review.decide!(decision: "exit", user: john, seen_as_of: "2026-10-14")
    Allocation::DriftJob.perform_now # a same-day rerun keeps the decided review's row
    expect(target.drifts.sole).to have_attributes(action: "thesis_review", thesis_review: review)
    expect(described_class.count).to eq(1)

    script_price_history(symbol: "TQQQ", close: 53)
    Proposals::Create.call(account: account, kind: :exit, side: :sell, symbol: "TQQQ", limit_price: 54, quantity: 10, origin: :human, user: john)
    next_night(Date.new(2026, 10, 15))
    expect(target.drifts.order(:as_of).last).to have_attributes(action: "existing_proposal", thesis_review: nil)
    expect(described_class.count).to eq(1)

    OrderProposal.update_all(status: "rejected")
    next_night(Date.new(2026, 10, 16))
    expect(described_class.open.count).to eq(1) # the operator walked away from the exit: ask again
  end

  it "answers a review left open after the tag comes off before anything mechanical, and a hold still stands untagged" do
    target = Allocation::Target.add!(symbol: "TQQQ", target_percent: "10", user: john)
    Allocation::DriftJob.perform_now
    tqqq.classify!(asset_class: nil, tags: [], user: john)
    next_night(Date.new(2026, 10, 15))
    expect(target.drifts.order(:as_of).last).to have_attributes(action: "thesis_review", thesis_review: described_class.sole)
    expect(OrderProposal.count).to eq(0)

    described_class.sole.decide!(decision: "hold", reason: "core position", user: john)
    next_night(Date.new(2026, 10, 16))
    expect(target.drifts.order(:as_of).last).to have_attributes(action: "rejected_standing", thesis_review: described_class.sole)
    expect(OrderProposal.count).to eq(0)
  end

  it "never writes the night's numbers onto a review decided meanwhile, and refuses a decision on numbers since refreshed" do
    Allocation::Target.add!(symbol: "TQQQ", target_percent: "10", user: john)
    Allocation::DriftJob.perform_now
    review = described_class.sole
    expect { review.decide!(decision: "hold", reason: "r", user: john, seen_as_of: "2026-10-13") }.to raise_error(ActiveRecord::StaleObjectError)
    review.decide!(decision: "hold", reason: "r", user: john, seen_as_of: "2026-10-14")
    drift = Allocation::Drift.sole
    expect(described_class.raise_for!(account: account, drift: drift)).not_to eq(review) # a decided review is not refreshed
    expect(review.reload.context["as_of"]).to eq("2026-10-14")
  end

  it "does not carry a hold over to a new target on the same instrument" do
    first = Allocation::Target.add!(symbol: "TQQQ", target_percent: "10", user: john)
    Allocation::DriftJob.perform_now
    described_class.sole.decide!(decision: "hold", reason: "r", user: john)
    first.retire!(user: john)
    second = Allocation::Target.add!(symbol: "TQQQ", target_percent: "10", user: john)
    next_night(Date.new(2026, 10, 15))
    expect(second.drifts.sole).to have_attributes(action: "thesis_review")
    expect(described_class.open.count).to eq(1)
  end
end
