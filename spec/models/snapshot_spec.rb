require "rails_helper"

RSpec.describe Snapshot do
  let(:account) { create(:account, trading_enabled: true) }

  def balance(date, equity, at: "16:05")
    create(:balance, account: account, as_of: Time.zone.parse("#{date} #{at} EDT"), equity: equity)
  end

  def record(day) = travel_to(Time.zone.parse("2026-09-#{day} 16:30 EDT")) { Snapshot.record(account, Date.new(2026, 9, day)) }

  before { (Date.new(2026, 9, 8)..Date.new(2026, 9, 12)).each { |d| MarketDay.for(d) } }

  it "starts at index 1, and a deposit or withdrawal never moves the index, whatever sign Schwab sent" do
    balance("2026-09-08", 10_000)
    balance("2026-09-09", 15_000)
    flow(account, "deposit", 5_000, on: Date.new(2026, 9, 9))
    balance("2026-09-10", 10_000)
    flow(account, "withdrawal", 5_000, on: Date.new(2026, 9, 10), sign: 1) # an outbound type with a positive net amount
    balance("2026-09-11", 9_000)
    (8..11).each { |d| record(d) }
    s = account.snapshots.chronological.to_a
    expect(s.map(&:daily_return).map(&:to_f)).to eq([ 0.0, 0.0, 0.0, -0.1 ])
    expect(s.map(&:net_flows).map(&:to_f)).to eq([ 0.0, 5_000.0, -5_000.0, 0.0 ])
    expect(s.last.index_value.to_f).to be_within(0.0001).of(0.9)
    expect(s.last.drawdown.to_f).to be_within(0.0001).of(0.1)
  end

  it "neutralizes a flow that landed on a day with no snapshot" do
    balance("2026-09-08", 10_000)
    record(8)
    flow(account, "deposit", 5_000, on: Date.new(2026, 9, 9)) # no balance on the 9th: paused sync
    balance("2026-09-10", 15_000)
    expect(record(9)).to be_nil
    record(10)
    expect(account.snapshots.find_by(as_of: Date.new(2026, 9, 10)).daily_return).to eq(0)
  end

  it "uses the post-close balance, and writes nothing before the close, on weekends, on fallback days, or at zero equity" do
    balance("2026-09-08", 9_000, at: "15:50")
    balance("2026-09-08", 10_000, at: "16:10")
    expect(travel_to(Time.zone.parse("2026-09-08 16:15 EDT")) { Snapshot.record(account, Date.new(2026, 9, 8)) }).to be_nil
    expect(record(8).equity).to eq(10_000)
    expect(record(12)).to be_nil
    MarketDay.find_by(date: Date.new(2026, 9, 9)).update!(source: :fallback)
    balance("2026-09-09", 10_000)
    expect(record(9)).to be_nil
    balance("2026-09-10", 0)
    expect(record(10)).to be_nil
  end

  it "rechains forward from a date in place, keeping each day's risk columns" do
    balance("2026-09-08", 10_000)
    balance("2026-09-09", 11_000)
    balance("2026-09-10", 12_000)
    (8..10).each { |d| record(d) }
    account.snapshots.find_by(as_of: Date.new(2026, 9, 9)).update!(open_risk_amount: 164, unprotected_count: 2)
    flow(account, "deposit", 1_000, on: Date.new(2026, 9, 9))
    # do/end, not braces: a brace block here would bind to Time.zone.parse and the job would run outside the travel.
    travel_to Time.zone.parse("2026-09-10 17:00 EDT") do
      Snapshots::RebuildJob.perform_now(account, from: Date.new(2026, 9, 9))
    end
    ninth = account.snapshots.find_by(as_of: Date.new(2026, 9, 9))
    expect(ninth.daily_return).to eq(0)
    expect(ninth).to have_attributes(open_risk_amount: 164, unprotected_count: 2)
    expect(account.snapshots.find_by(as_of: Date.new(2026, 9, 10)).index_value.to_f).to be_within(0.0001).of(12.0 / 11)
    expect(account.snapshots.count).to eq(3)
  end

  it "does not write today from an intraday balance during a rebuild" do
    balance("2026-09-08", 10_000)
    record(8)
    balance("2026-09-09", 10_500, at: "10:05")
    travel_to Time.zone.parse("2026-09-09 10:10 EDT") do
      Snapshots::RebuildJob.perform_now(account, from: Date.new(2026, 9, 9))
    end
    expect(account.snapshots.find_by(as_of: Date.new(2026, 9, 9))).to be_nil
  end

  it "carries open risk and the unprotected count, and quarantines an unpriced share transfer" do
    balance("2026-09-08", 10_000)
    xyz = create(:instrument)
    stop = create(:order, :working_stop, account: account, instrument: xyz, stop_price: 48.9)
    create(:position, account: account, instrument: xyz, quantity: 40, last_price: 53, working_stop_order: stop)
    create(:position, account: account, instrument: create(:instrument), quantity: 10, last_price: 20)
    delivery(account, xyz, 5, at: Time.zone.parse("2026-09-08 09:00 EDT"))
    run = create(:sync_run, feed: "snapshots", account: account, status: "running", finished_at: nil)
    snapshot = travel_to(Time.zone.parse("2026-09-08 16:30 EDT")) { Snapshot.record(account, Date.new(2026, 9, 8), run: run) }
    expect(snapshot.open_risk_amount).to eq(164)
    expect(snapshot.open_risk_ratio.to_f).to be_within(0.0001).of(0.0164)
    expect(snapshot.unprotected_count).to eq(1)
    expect(run.reload.unmapped_values.keys).to eq([ "unpriced_transfers" ])
  end
end
