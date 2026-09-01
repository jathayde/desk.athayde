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
    expect(Position.protected_by_stop).to include(position)
  end

  it "reports unknown risk without a stop, never zero" do
    position = position_with(nil)
    expect(position).to be_unprotected
    expect(position.distance_to_stop).to be_nil
    expect(position.open_risk).to be_nil
    expect(Position.unprotected).to include(position)
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
