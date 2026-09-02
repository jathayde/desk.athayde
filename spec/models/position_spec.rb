require "rails_helper"

RSpec.describe Position do
  let(:account) { create(:account) }
  let(:instrument) { create(:instrument) }

  def position_with(stop, last_price: 53.00)
    create(:position, account: account, instrument: instrument, quantity: 40, last_price: last_price, working_stop_order: stop)
  end

  it "is protected by a working stop with a price, and reports distance and dollars at risk" do
    position = position_with(create(:order, :working_stop, account: account, instrument: instrument))
    expect(position).to be_protected
    expect(position.distance_to_stop).to be_within(0.0001).of(0.0774)
    expect(position.open_risk).to eq(164.0)
  end

  it "calls a stop-covered position with no last price unpriced, with unknown risk, never a crash" do
    position = position_with(create(:order, :working_stop, account: account, instrument: instrument))
    position.update!(last_price: nil, market_value: nil)
    expect(position.protection).to eq(:unpriced)
    expect(position.open_risk).to be_nil
    expect(position.distance_to_stop).to be_nil
  end

  it "reports unknown risk without a stop, never zero" do
    position = position_with(nil)
    expect(position).to be_unprotected
    expect(position.distance_to_stop).to be_nil
    expect(position.open_risk).to be_nil
  end

  it "treats a trailing stop without a readable price as unknown risk rather than crashing" do
    position = position_with(create(:order, :trailing_stop, account: account, instrument: instrument))
    expect(position).to be_unprotected
    expect(position.open_risk).to be_nil
  end

  it "stops trusting a stop order once it is no longer working" do
    stop = create(:order, :working_stop, account: account, instrument: instrument)
    position = position_with(stop)
    stop.update!(status: "FILLED")
    expect(position.reload).to be_unprotected
  end

  it "floors open risk at zero once price has gapped through the stop" do
    position = position_with(create(:order, :working_stop, account: account, instrument: instrument, stop_price: 48.90), last_price: 40.00)
    expect(position.distance_to_stop).to be < 0
    expect(position.open_risk).to eq(0)
  end

  it "is unique per account and instrument" do
    position_with(nil)
    expect(build(:position, account: account, instrument: instrument)).not_to be_valid
  end
end

RSpec.describe Order, ".terminal" do
  it "means not replaced by any order, even when chained after a status scope" do
    account = create(:account)
    instrument = create(:instrument)
    old = create(:order, :working_stop, account: account, instrument: instrument, status: "REPLACED")
    create(:order, :working_stop, account: account, instrument: instrument, status: "CANCELED", replaces_order: old)
    expect(account.orders.stops.sells.working.terminal).not_to include(old)
  end
end

RSpec.describe Position, "with two live stops" do
  let(:account) { create(:account) }
  let(:instrument) { create(:instrument) }

  it "sums each tranche at its own stop price and calls the pair unknown when one has no price" do
    older = create(:order, :working_stop, account: account, instrument: instrument, quantity: 20, remaining_quantity: 20, stop_price: 48, entered_at: 2.days.ago)
    newer = create(:order, :working_stop, account: account, instrument: instrument, quantity: 20, remaining_quantity: 20, stop_price: 50, entered_at: 1.day.ago)
    position = create(:position, account: account, instrument: instrument, quantity: 40, last_price: 53, working_stop_order: newer)
    expect(position.protection).to eq(:protected)
    expect(position.open_risk).to eq(20 * 5 + 20 * 3)
    older.update!(stop_price: nil)
    expect(position.reload.protection).to eq(:trailing_unknown)
    expect(position.open_risk).to be_nil
  end
end

RSpec.describe Account, "#label" do
  it "never carries a hash fragment" do
    first = create(:account, nickname: nil, account_type: nil, trading_enabled: false)
    expect(first.label).to eq("Account #{first.id}")
    expect(first.label).not_to include(first.schwab_hash.last(4))
  end
end
