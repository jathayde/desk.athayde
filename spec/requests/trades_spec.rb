require "rails_helper"

RSpec.describe "Trades" do
  let(:user) { create(:user) }
  let(:account) { create(:account, trading_enabled: true) }
  let(:xyz) { create(:instrument, symbol: "XYZ") }
  before { sign_in user }

  def trade_with_entry(**attrs)
    create(:trade, { account: account, instrument: xyz, needs_review: true, review_reason: "missing_setup", avg_entry: 50 }.merge(attrs)).tap do |trade|
      trade.trade_legs.create!(kind: "entry", quantity: 40, price: 50, executed_at: Time.current, activity: create(:activity, account: account, instrument: trade.instrument))
    end
  end

  it "links a trade to the proposal that opened it" do
    proposal = create(:order_proposal, account: account, instrument: xyz, status: "filled", origin: "agent")
    trade = trade_with_entry(order_proposal: proposal, needs_review: false, review_reason: nil)
    get trade_path(trade)
    expect(response.body).to include("BUY 10 XYZ @ $50.00, agent", proposal_path(proposal))
  end

  it "lists by filter and orders the review queue by seriousness, then never-skipped, then oldest" do
    a = create(:trade, account: account, instrument: xyz, needs_review: true, review_reason: "missing_setup", created_at: 3.days.ago)
    b = create(:trade, account: account, instrument: create(:instrument), needs_review: true, review_reason: "corporate_action", created_at: 1.day.ago)
    c = create(:trade, account: account, instrument: create(:instrument), needs_review: true, review_reason: "missing_setup", created_at: 2.days.ago, review_deferred_at: 1.hour.ago)
    create(:trade, account: create(:account, trading_enabled: false), instrument: xyz, needs_review: true, review_reason: "missing_setup")
    expect(Trade.review_queue.map(&:id)).to eq([ b.id, a.id, c.id ])
    get trades_path(filter: "needs_review")
    expect(response.body).to include("Needs review (3)").and include("No setup recorded")
    get trades_path(filter: "closed")
    expect(response.body).to include("No closed trades.")
  end

  it "reviews a trade: creates a setup by name, sets the stop, and moves to the next in the queue" do
    trade = trade_with_entry
    following = create(:trade, account: account, instrument: create(:instrument), needs_review: true, review_reason: "missing_setup")
    patch trade_review_path(trade), params: { new_setup: "breakout-A", planned_stop: "48", thesis: "base breakout" }
    expect(response).to redirect_to(trade_review_path(following))
    expect(trade.reload).to have_attributes(needs_review: false, planned_stop: 48, thesis: "base breakout", initial_risk: 80)
    expect(trade.setup.name).to eq("breakout-A")
  end

  it "reuses an existing setup name case-insensitively instead of failing" do
    create(:setup, name: "Breakout-A")
    trade = trade_with_entry
    patch trade_review_path(trade), params: { new_setup: "breakout-a" }
    expect(trade.reload.setup.name).to eq("Breakout-A")
    expect(Setup.count).to eq(1)
  end

  it "refuses a review without a setup, a stop above the entry, or a non-numeric stop, and re-renders the form" do
    trade = trade_with_entry
    patch trade_review_path(trade), params: { thesis: "x" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Setup is required")
    patch trade_review_path(trade), params: { new_setup: "b", planned_stop: "55" }
    expect(response.body).to include("gives no risk to measure")
    patch trade_review_path(trade), params: { new_setup: "b", planned_stop: "abc" }
    expect(response).to redirect_to(trades_path(filter: "needs_review"))
    expect(trade.reload).to have_attributes(planned_stop: nil, initial_risk: nil, needs_review: false)
  end

  it "skips durably, and skipping the only item lands on the queue with it still there" do
    trade = create(:trade, account: account, instrument: xyz, needs_review: true, review_reason: "bootstrapped")
    post trade_deferral_path(trade)
    expect(trade.reload.review_deferred_at).to be_present
    expect(response).to redirect_to(trades_path(filter: "needs_review"))
    expect(Trade.review_queue).to include(trade)
  end

  it "excludes as not a setup trade, and the exclusion survives the next bootstrap run" do
    trade = trade_with_entry
    create(:position, account: account, instrument: xyz, quantity: 40, average_price: 50, synced_at: 1.minute.from_now)
    post trade_exclusion_path(trade)
    expect(trade.reload).to have_attributes(excluded_from_stats: true, needs_review: false)
    Journal::BootstrapJob.perform_now(account)
    expect(trade.reload).not_to be_needs_review
    expect(response).to redirect_to(trades_path(filter: "needs_review"))
  end

  it "keeps a reviewed trade reviewed after a bootstrap run" do
    trade = trade_with_entry
    create(:position, account: account, instrument: xyz, quantity: 40, average_price: 50, synced_at: 1.minute.from_now)
    patch trade_review_path(trade), params: { new_setup: "b", planned_stop: "48" }
    Journal::BootstrapJob.perform_now(account)
    expect(trade.reload).not_to be_needs_review
  end

  it "takes the post-mortem in two inputs and refuses half of one" do
    trade = create(:trade, account: account, instrument: xyz, status: "closed")
    patch trade_path(trade), params: { post_mortem: "held to target" }
    expect(trade.reload.post_mortem).to be_nil
    patch trade_path(trade), params: { post_mortem: "held to target", followed_setup: "1" }
    expect(trade.reload).to have_attributes(post_mortem: "held to target", followed_setup: true)
    get trade_path(trade)
    expect(response.body).to include("held to target").and include("not hit")
  end

  it "renders the review form with the legacy copy for a closed bootstrapped trade" do
    trade = create(:trade, account: account, instrument: xyz, status: "closed", bootstrapped: true, needs_review: true, review_reason: "bootstrapped")
    get trade_review_path(trade)
    expect(response.body).to include("Closed legacy holding").and include("Legacy holding: the entry predates the journal")
  end
end
