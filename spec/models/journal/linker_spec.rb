require "rails_helper"

RSpec.describe Journal::Linker do
  let(:account) { create(:account, trading_enabled: true) }
  let(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:t0) { Time.zone.parse("2026-08-14 10:00 EDT") }

  it "journals buy 40, sell 40 into one closed trade with P&L from leg cash amounts" do
    fill(account, xyz, "BUY", 40, 50, at: t0, fees: 1)
    fill(account, xyz, "SELL", 40, 55, at: t0 + 2.days, fees: 1)
    link!(account)
    trade = account.trades.sole
    expect(trade).to be_closed
    expect(trade.trade_legs.map(&:kind)).to eq(%w[ entry exit ])
    expect(trade).to have_attributes(peak_quantity: 40, quantity: 0, avg_entry: 50, avg_exit: 55, realized_pnl: BigDecimal("198"), initial_quantity: 40)
    expect(trade.realized_r).to be_nil
    expect(trade).to be_needs_review.and be_review_missing_setup
    expect(Activity.unjournaled).to be_empty
  end

  it "computes R from the initial entry once a stop is known, and total risk across every entry" do
    fill(account, xyz, "BUY", 40, 50, at: t0)
    fill(account, xyz, "BUY", 20, 52, at: t0 + 1.day)
    fill(account, xyz, "SELL", 30, 55, at: t0 + 2.days)
    fill(account, xyz, "SELL", 30, 54, at: t0 + 3.days)
    link!(account)
    trade = account.trades.sole
    expect(trade).to be_closed
    expect(trade.peak_quantity).to eq(60)
    expect(trade.avg_entry).to be_within(0.01).of(50.67)
    expect(trade.avg_exit).to eq(BigDecimal("54.5"))
    expect(trade.realized_pnl).to eq(230)
    trade.review!(setup: create(:setup), planned_stop: 48, thesis: "breakout", user: create(:user))
    expect(trade.reload).to have_attributes(initial_quantity: 40, initial_risk: 80, total_risk: 160, realized_r: BigDecimal("2.875"))
    expect(trade).not_to be_needs_review
    expect(AuditEvent.where(kind: "trade_reviewed")).to exist
  end

  it "treats a partial fill on one order as one initial entry at its weighted price" do
    order = create(:order, account: account, instrument: xyz, broker_order_id: "777")
    fill(account, xyz, "BUY", 25, 50, at: t0, order: order)
    fill(account, xyz, "BUY", 15, 50.2, at: t0 + 1.minute, order: order)
    link!(account)
    trade = account.trades.sole
    trade.update!(planned_stop: 48)
    trade.recompute!
    expect(trade.initial_quantity).to eq(40)
    expect(trade.initial_risk).to eq(BigDecimal("83"))
  end

  it "bootstraps a legacy holding when the first fill is a sale, covering what was held before" do
    create(:position, account: account, instrument: xyz, quantity: 25, average_price: 40)
    fill(account, xyz, "SELL", 15, 55, at: t0)
    link!(account)
    trade = account.trades.sole
    expect(trade).to be_open.and be_bootstrapped.and be_review_bootstrapped
    expect(trade.trade_legs.find_by(activity_id: nil)).to have_attributes(quantity: 40, price: 40)
    expect(trade.quantity).to eq(25)
    expect(trade.peak_quantity).to eq(40)
  end

  it "leaves P&L unknown when a legacy sale has no position to price the plug from" do
    fill(account, xyz, "SELL", 15, 55, at: t0)
    link!(account)
    trade = account.trades.sole
    expect(trade).to be_closed.and be_bootstrapped
    expect(trade.realized_pnl).to be_nil
    expect(trade.initial_risk).to be_nil
  end

  it "reconciles the plug against the broker so an entry inside the sync window is not double counted, and clears the flag" do
    create(:position, account: account, instrument: xyz, quantity: 40, average_price: 50, synced_at: t0 + 1.hour)
    Journal::BootstrapJob.perform_now(account)
    expect(account.trades.sole.trade_legs.sole.quantity).to eq(40)
    fill(account, xyz, "BUY", 40, 50, at: t0)
    Journal::LinkFillsJob.perform_now(account)
    trade = account.trades.sole
    expect(trade.trade_legs.where(activity_id: nil)).not_to exist
    expect(trade.quantity).to eq(40)
    expect(trade).not_to be_bootstrapped
    expect(trade).to be_review_missing_setup
  end

  it "does not manufacture a plug or a missing-position flag from a positions row older than the latest fill" do
    fill(account, xyz, "BUY", 40, 50, at: t0)
    link!(account)
    create(:position, account: account, instrument: xyz, quantity: 60, average_price: 50, synced_at: t0 - 1.hour)
    Journal::LinkFillsJob.perform_now(account)
    expect(account.trades.sole.trade_legs.where(activity_id: nil)).not_to exist
    fill(account, xyz, "SELL", 40, 55, at: t0 + 1.day)
    link!(account)
    account.positions.destroy_all
    Journal::BootstrapJob.perform_now(account)
    expect(account.trades.sole).to be_closed
    expect(account.trades.sole).not_to be_review_position_missing
  end

  it "copies the plan from an originating proposal and needs no review" do
    proposal = OrderProposal.create!(account: account, instrument: xyz, origin: :agent, side: "BUY", setup: create(:setup, name: "breakout-A"), thesis: "t", planned_stop: 48, target_price: 56)
    order = create(:order, account: account, instrument: xyz, order_proposal: proposal, broker_order_id: "888")
    fill(account, xyz, "BUY", 40, 50, at: t0, order: order)
    link!(account)
    trade = account.trades.sole
    expect(trade).to have_attributes(setup: proposal.setup, planned_stop: 48, planned_target: 56, initial_risk: 80, needs_review: false)
  end

  it "lets a rebalance fill join the open trade without replacing its plan, and asks for one on a trade a rebalance opened" do
    entry = OrderProposal.create!(account: account, instrument: xyz, origin: :agent, side: "BUY", status: "filled", setup: create(:setup, name: "breakout-A"), thesis: "t", planned_stop: 48)
    fill(account, xyz, "BUY", 40, 50, at: t0, order: create(:order, account: account, instrument: xyz, order_proposal: entry))
    rebalance = OrderProposal.create!(account: account, instrument: xyz, kind: :rebalance, origin: :allocation, side: "BUY", quantity: 5, limit_price: 51, thesis: "Rebalance XYZ")
    fill(account, xyz, "BUY", 5, 51, at: t0 + 1.day, order: create(:order, account: account, instrument: xyz, order_proposal: rebalance))
    link!(account)
    expect(account.trades.sole).to have_attributes(order_proposal: entry, planned_stop: 48, thesis: "t", needs_review: false, peak_quantity: 45)

    def_ = create(:instrument, symbol: "DEF", cusip: "594918104")
    buy = OrderProposal.create!(account: account, instrument: def_, kind: :rebalance, origin: :allocation, side: "BUY", quantity: 3, limit_price: 86)
    fill(account, def_, "BUY", 3, 86, at: t0 + 2.days, order: create(:order, account: account, instrument: def_, order_proposal: buy))
    link!(account)
    expect(account.trades.find_by!(instrument: def_)).to have_attributes(needs_review: true, review_reason: "missing_setup", order_proposal: nil)
  end

  it "records a stop-out when the closing exit came from a stop order, and recomputes it from the legs" do
    stop = create(:order, :working_stop, account: account, instrument: xyz, status: "FILLED")
    fill(account, xyz, "BUY", 40, 50, at: t0)
    exit_fill = fill(account, xyz, "SELL", 40, 48.9, at: t0 + 1.day, order: stop)
    link!(account)
    expect(account.trades.sole).to be_stopped_out
    exit_fill.unjournal!
    expect(account.trades.sole).not_to be_stopped_out
  end

  it "adds a mid-trade dividend as income and a post-close dividend to the recent trade" do
    fill(account, xyz, "BUY", 40, 50, at: t0)
    income(account, xyz, 12, at: t0 + 1.day)
    fill(account, xyz, "SELL", 40, 55, at: t0 + 2.days)
    income(account, xyz, 5, at: t0 + 10.days)
    link!(account)
    trade = account.trades.sole
    expect(trade.trade_legs.kind_income.count).to eq(2)
    expect(trade.realized_pnl).to eq(217)
    expect(trade.avg_entry).to eq(50)
  end

  it "applies a 2:1 split delivered through the mapper: quantity doubles, the stop displays halved, risk unchanged, and the next bootstrap adds no plug" do
    fill(account, xyz, "BUY", 40, 50, at: t0)
    link!(account)
    trade = account.trades.sole
    trade.update!(planned_stop: 48)
    trade.recompute!
    delivery(account, xyz, 40, at: t0 + 5.days)
    link!(account)
    expect(trade.reload).to have_attributes(quantity: 80, avg_entry: 25, planned_stop: 48, current_planned_stop: 24, initial_risk: 80)
    create(:position, account: account, instrument: xyz, quantity: 80, average_price: 25, synced_at: t0 + 6.days)
    Journal::BootstrapJob.perform_now(account)
    expect(trade.reload.trade_legs.where(activity_id: nil)).not_to exist
    expect(trade.quantity).to eq(80)
    fill(account, xyz, "SELL", 80, 30, at: t0 + 6.days)
    link!(account)
    expect(trade.reload).to be_closed
    expect(trade.realized_pnl).to eq(400)
    expect(trade.realized_r).to eq(5)
  end

  it "moves a trade across a CUSIP succession, absorbing a bootstrapped trade on the new instrument" do
    fill(account, xyz, "BUY", 40, 50, at: t0)
    link!(account)
    new_instrument = create(:instrument, symbol: "NEWCO", cusip: "222222222")
    create(:position, account: account, instrument: new_instrument, quantity: 20, average_price: 100, synced_at: t0 + 1.day)
    Journal::BootstrapJob.perform_now(account)
    raw = { "activityId" => 777, "type" => "RECEIVE_AND_DELIVER", "tradeDate" => "2026-08-20T00:00:00+0000", "netAmount" => 0, "transferItems" => [
      { "instrument" => { "assetType" => "EQUITY", "cusip" => "037833100", "symbol" => "XYZ" }, "amount" => -40 },
      { "instrument" => { "assetType" => "EQUITY", "cusip" => "222222222", "symbol" => "NEWCO" }, "amount" => 20 } ] }
    create(:activity, account: account, instrument: xyz, kind: "corporate_action", quantity: nil, side: nil, net_amount: 0, executed_at: t0 + 6.days, trade_date: (t0 + 6.days).to_date, status: "VALID", raw: raw)
    link!(account)
    trade = account.trades.sole
    expect(trade.instrument).to eq(new_instrument)
    expect(new_instrument.reload.predecessor_instrument).to eq(xyz)
    expect(trade.quantity).to eq(20)
    expect(trade.avg_entry).to eq(100)
  end

  it "flags a fill that arrives out of order instead of forking the trade" do
    fill(account, xyz, "BUY", 40, 50, at: t0 + 1.day)
    link!(account)
    fill(account, xyz, "BUY", 10, 49, at: t0)
    link!(account)
    trade = account.trades.sole
    expect(trade.quantity).to eq(50)
    expect(trade).to be_review_ordering_ambiguous
  end

  it "drops the leg and rebuilds when a journaled activity changes" do
    fill(account, xyz, "BUY", 40, 50, at: t0)
    link!(account)
    entry = account.activities.sole
    entry.update!(quantity: 30)
    entry.unjournal!
    expect(account.trades.sole.quantity).to eq(0)
    link!(account)
    expect(account.trades.sole.quantity).to eq(30)
  end

  it "stamps invalid activities without journaling them" do
    fill(account, xyz, "BUY", 40, 50, at: t0)
    pending = fill(account, xyz, "SELL", 40, 55, at: t0 + 1.day, status: "PENDING")
    link!(account)
    expect(account.trades.sole).to be_open
    expect(pending.reload).to be_journaled
    expect(pending.trade_leg).to be_nil
  end

  it "keeps journaling the account when one activity fails" do
    fill(account, xyz, "BUY", 40, 50, at: t0)
    broken = fill(account, create(:instrument, symbol: "BAD"), "BUY", 10, 5, at: t0 + 1.minute)
    allow_any_instance_of(Trade).to receive(:recompute!).and_wrap_original { |m, *a| raise ActiveRecord::RecordInvalid if m.receiver.instrument.symbol == "BAD"; m.call(*a) }
    link!(account)
    expect(account.activities.find_by(instrument: xyz)).to be_journaled
    expect(broken.reload).not_to be_journaled
  end

  it "leaves a fill with no side unjournaled rather than losing it" do
    create(:activity, account: account, instrument: xyz, kind: "fill", side: nil, quantity: 10, price: 5, net_amount: -50, executed_at: t0, trade_date: t0.to_date, status: "VALID")
    link!(account)
    expect(account.activities.unjournaled.count).to eq(1)
  end

  it "never journals the IRA" do
    ira = create(:account, trading_enabled: false, account_type: "ira")
    fill(ira, xyz, "BUY", 10, 50, at: t0)
    Journal::LinkFillsJob.perform_now(ira)
    expect(Trade.count).to eq(0)
  end

  it "ignores sweeps and cash movements" do
    create(:activity, account: account, instrument: create(:instrument, symbol: "SWVXX", asset_type: "CASH_EQUIVALENT"), kind: "sweep", net_amount: -500, executed_at: t0, trade_date: t0.to_date, status: "VALID")
    flow(account, "deposit", 1000, on: t0.to_date)
    link!(account)
    expect(Trade.count).to eq(0)
    expect(account.activities.unjournaled).to be_empty
  end

  it "keeps a closed legacy holding out of the stats even after review, and takes no stop for it" do
    create(:position, account: account, instrument: xyz, quantity: 40, average_price: 50, synced_at: t0)
    Journal::BootstrapJob.perform_now(account)
    fill(account, xyz, "SELL", 40, 55, at: t0 + 1.day)
    link!(account)
    trade = account.trades.sole
    expect(trade).to be_closed.and be_bootstrapped
    trade.review!(setup: create(:setup), planned_stop: 45, thesis: "legacy", user: create(:user))
    expect(trade.reload.planned_stop).to be_nil
    expect(Trade.eligible_for_stats).not_to include(trade)
  end
end
