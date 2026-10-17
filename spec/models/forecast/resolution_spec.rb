require "rails_helper"

# The scoring rule (docs/phase-2.6-plan.md §0.1) against hand-built paths: entry 50, stop 47, target 56, made after
# the open on Monday, so the window opens Tuesday and the reference is Monday's final close of 50.
RSpec.describe Forecast::Resolution do
  let(:monday) { Date.new(2026, 10, 5) }
  let(:forecast) { Forecast.new(entry_price: 50, stop_price: 47, target_price: 56, reference_close: 50, reference_on: monday, starts_on: monday + 1, horizon_days: 3) }

  # One candle per weekday from Monday: [low, high], closing at the middle unless given.
  def path(*bars)
    days = (0..20).map { monday + it }.reject(&:on_weekend?)
    bars.each_with_index.map { |(low, high, close), i| { date: days[i], low: low.to_d, high: high.to_d, close: (close || (low + high) / 2.0).to_d } }
  end

  def resolve(*bars) = described_class.call(forecast, path(*bars))

  it "enters on the first session from starts_on whose low reaches the limit, then scores the target before the stop" do
    verdict = resolve([ 49, 51, 50 ], [ 50.5, 52 ], [ 49.5, 53 ], [ 51, 56.5 ])
    expect(verdict).to have_attributes(outcome: "hit", void_reason: nil, checked_through: monday + 3)
    expect(verdict.detail).to include("entered_on" => (monday + 2).iso8601, "decided_on" => (monday + 3).iso8601, "resolver_version" => 1)
  end

  it "never reads the reference day, even when its range touched the levels" do
    expect(resolve([ 46, 57, 50 ], [ 49.5, 52 ]).outcome).to be_nil
  end

  it "tests only the stop on the entry day, and calls it ambiguous" do
    verdict = resolve([ 49, 51, 50 ], [ 46.5, 57 ])
    expect(verdict).to have_attributes(outcome: "miss")
    expect(verdict.detail).to include("ambiguous" => true, "stopped_on_entry_day" => true)
  end

  it "counts a day touching both levels as the stop, marked ambiguous, and a gap through the stop as a miss" do
    expect(resolve([ 49, 51, 50 ], [ 49.5, 52 ], [ 46, 57 ]).detail).to include("ambiguous" => true)
    gapped = resolve([ 49, 51, 50 ], [ 49.5, 52 ], [ 44, 45.5 ])
    expect(gapped.outcome).to eq("miss")
    expect(gapped.detail).not_to include("ambiguous")
  end

  it "is a miss marked expired once the horizon's last candle exists untouched, and open while it runs" do
    expect(resolve([ 49, 51, 50 ], [ 49.5, 52 ], [ 50, 53 ], [ 50, 53 ]).outcome).to be_nil
    expect(resolve([ 49, 51, 50 ], [ 49.5, 52 ], [ 50, 53 ], [ 50, 53 ], [ 50, 53 ]).detail).to include("expired" => true)
    expect(resolve([ 49, 51, 50 ], [ 49.5, 52 ], [ 50, 53 ], [ 50, 53 ], [ 50, 53 ]).outcome).to eq("miss")
  end

  it "voids as never entered after five sessions without a touch, and waits before that" do
    expect(resolve([ 49, 51, 50 ], *[ [ 51, 53 ] ] * 4).outcome).to be_nil
    expect(resolve([ 49, 51, 50 ], *[ [ 51, 53 ] ] * 5)).to have_attributes(outcome: "void", void_reason: "never_entered")
  end

  it "voids rather than mis-resolves a restated reference close or a move that lands on a split ratio" do
    expect(resolve([ 24, 26, 25 ], [ 24.5, 26 ])).to have_attributes(outcome: "void", void_reason: "split")
    split = resolve([ 49, 51, 50 ], [ 49.5, 52 ], [ 24, 26, 25 ])
    expect(split).to have_attributes(outcome: "void", void_reason: "split")
    expect(split.detail).to include("moved_on" => (monday + 2).iso8601)
  end

  it "ignores a jump after the deciding day" do
    expect(resolve([ 49, 51, 50 ], [ 49.5, 52 ], [ 51, 56.5 ], [ 24, 26, 25 ]).outcome).to eq("hit")
  end

  it "scores a real crash or spike however large, and voids a 3:2 split" do
    crash = resolve([ 49, 51, 50 ], [ 49.5, 52, 50 ], [ 28, 31, 30 ]) # −40%: no split ratio
    expect(crash.outcome).to eq("miss")
    expect(resolve([ 49, 51, 50 ], [ 49.5, 52, 51 ], [ 33, 35, 34 ])).to have_attributes(outcome: "void", void_reason: "split") # 51 → 34 is 2:3
  end

  it "takes equal touches as touches, and a gap through the target as a plain hit" do
    expect(resolve([ 49, 51, 50 ], [ 50, 52 ], [ 51, 56 ]).outcome).to eq("hit") # low = entry, high = target
    expect(resolve([ 49, 51, 50 ], [ 50, 52 ], [ 47, 52 ]).outcome).to eq("miss") # low = stop
    gapped = resolve([ 49, 51, 50 ], [ 50, 52 ], [ 57, 58 ])
    expect(gapped.outcome).to eq("hit")
    expect(gapped.detail).not_to include("ambiguous")
  end

  it "enters on the fifth session of the window and not the sixth" do
    expect(resolve([ 49, 51, 50 ], *[ [ 51, 53 ] ] * 4, [ 49.5, 52 ]).detail).to include("entered_on" => (monday + 7).iso8601)
    expect(resolve([ 49, 51, 50 ], *[ [ 51, 53 ] ] * 5, [ 49.5, 52 ]).void_reason).to eq("never_entered")
  end

  it "reads a one-session horizon, and a stop on the horizon's last day is a miss, not expired" do
    forecast.horizon_days = 1
    expect(resolve([ 49, 51, 50 ], [ 49.5, 52 ], [ 50, 53 ]).detail).to include("expired" => true)
    forecast.horizon_days = 3
    last_day = resolve([ 49, 51, 50 ], [ 49.5, 52 ], [ 50, 53 ], [ 50, 53 ], [ 46, 53 ])
    expect(last_day.outcome).to eq("miss")
    expect(last_day.detail).not_to include("expired")
  end

  it "reads candles in date order whatever order they arrive in" do
    expect(described_class.call(forecast, path([ 49, 51, 50 ], [ 50.5, 52 ], [ 49.5, 53 ], [ 51, 56.5 ]).reverse).outcome).to eq("hit")
  end

  it "does not read across a skipped session or without the reference candle, and takes a known holiday for what it is" do
    bars = path([ 49, 51, 50 ], [ 49.5, 52 ], [ 50, 53 ], [ 51, 56.5 ])
    holed = bars.values_at(0, 1, 3)
    verdict = described_class.call(forecast, holed)
    expect(verdict.outcome).to be_nil
    expect(described_class.gap?(verdict)).to be(true)
    expect(described_class.call(forecast, holed, closed_days: [ bars[2][:date] ]).outcome).to eq("hit")
    expect(described_class.gap?(described_class.call(forecast, bars.drop(1)))).to be(true)
  end

  it "settles a name that ended: a miss once entered, on any night, and never entered otherwise" do
    expect(described_class.call(forecast, path([ 49, 51, 50 ], [ 49.5, 52 ]), ended: true)).to have_attributes(outcome: "miss", detail: include("ended_early" => true))
    forecast.detail = { "entered_on" => (monday + 1).iso8601 }
    expect(described_class.call(forecast, [], ended: true).outcome).to eq("miss")
    forecast.detail = {}
    expect(described_class.call(forecast, [], ended: true)).to have_attributes(outcome: "void", void_reason: "never_entered")
  end
end
