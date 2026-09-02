require "rails_helper"

# The broker can omit an amount or a price. Every surface that sums must then say unknown, never crash or count zero.
RSpec.describe "Unpriced broker inputs" do
  let!(:account) { create(:account) }

  it "classifies a signed cash type with no amount as other, and a flow with no amount as unpriced" do
    raw = { "activityId" => 1, "type" => "ELECTRONIC_FUND", "tradeDate" => "2026-09-01T14:00:00+0000", "transferItems" => [] }
    expect(Schwab::Activity.from(raw).kind).to eq(:other)
    expect(Schwab::Activity.from(raw.merge("type" => "JOURNAL")).kind).to eq(:other)
    flow = create(:activity, account: account, kind: "deposit", net_amount: nil, trade_date: Date.new(2026, 9, 1), executed_at: Time.current, status: "VALID", side: nil, quantity: nil, price: nil)
    expect(flow.flow_amount).to be_nil
  end

  it "quarantines an unpriced flow in the snapshot math and keeps the dashboard's day change readable" do
    create(:activity, account: account, kind: "deposit", net_amount: nil, trade_date: Date.new(2026, 9, 1), executed_at: Time.current, status: "VALID", side: nil, quantity: nil, price: nil)
    create(:activity, account: account, kind: "deposit", net_amount: 100, trade_date: Date.new(2026, 9, 1), executed_at: Time.current, status: "VALID", side: nil, quantity: nil, price: nil)
    run = SyncRun.create!(feed: :snapshots, account: account, status: :running, started_at: Time.current)
    expect(Snapshot.net_flows(account, after: Date.new(2026, 8, 31), through: Date.new(2026, 9, 1), run: run)).to eq(100)
    expect(run.unmapped_values["unpriced_flows"]).to be_present
    create(:schwab_token)
    create(:balance, account: account, equity: 6500, as_of: Time.current)
    account.snapshots.create!(as_of: MarketDay.today - 1, equity: 6300)
    expect(Desk.new.day_change).to be_nil # an unpriced flow makes the day change unknown, never off by that flow
  end

  it "excludes a stop-covered position with no price from every risk sum and names it" do
    instrument = create(:instrument)
    stop = create(:order, :working_stop, account: account, instrument: instrument)
    create(:position, account: account, instrument: instrument, quantity: 40, average_price: 50, last_price: nil, market_value: nil, working_stop_order: stop, synced_at: Time.current)
    create(:schwab_token)
    create(:balance, account: account, equity: 6500, as_of: Time.current)
    dashboard = Desk.new
    expect(dashboard.open_risk).to eq(0)
    expect(dashboard.excluded_by_reason).to eq(unpriced: 1)
    expect(Snapshot.risk_now(account, BigDecimal("6500"))).to include(open_risk_amount: 0, unprotected_count: 1)
  end

  it "blocks rather than discards a snapshot rebuild that collides with the daily snapshot" do
    expect(Snapshots::RebuildJob.concurrency_on_conflict).to eq(:block)
  end
end
