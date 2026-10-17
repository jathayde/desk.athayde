require "rails_helper"

RSpec.describe Research::Baseline do
  def baseline(**overrides) = described_class.probability(**{ entry: 50, stop: 47, target: 56, volatility: 0.02, horizon_days: 10, seed: 1 }.merge(overrides))

  it "is reproducible, and grows with the horizon and the volatility" do
    expect(baseline).to eq(baseline)
    expect(baseline(horizon_days: 30)).to be > baseline
    expect(baseline(volatility: 0.04)).to be > baseline
  end

  it "comes to the no-drift odds, the stop's distance over the whole range, once the horizon no longer binds" do
    expect(baseline(volatility: 0.06, horizon_days: 60)).to be_within(0.03).of(3.0 / 9)
  end

  it "is well below the no-drift odds when the horizon is short, which a baseline without it would ignore" do
    expect(baseline(horizon_days: 5)).to be < 0.1
  end

  it "exposes a marketable entry to the stop for the whole entry session, as the resolver does, which tells most where the stop is near" do
    near = { stop: 49.5, target: 51, horizon_days: 5 }
    expect(baseline(**near, marketable: true)).to be < baseline(**near, marketable: false)
  end
end
