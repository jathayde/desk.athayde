require "rails_helper"

RSpec.describe PriceChart do
  let(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:fake) { Schwab::FakeClient.instance }

  it "scales the last bars into the box with the stop, entry, and collar as lines, and reads the same cache the tools use" do
    fake.script_daily_history(symbol: "XYZ", close: 50, days: 200, range: 3) # bars from about 46 to 54
    collar = StopCollar::Collar.new(methods: {}, tight: 47.5, wide: 46.5, floor: 46.5, floor_dominates: false, quality: :ok, refusal: nil)
    chart = described_class.for(xyz, stop: 45, entry: 48, collar: collar)
    expect(chart).to be_drawable
    expect(chart.bars.size).to eq(described_class::BARS)
    expect(chart.lines.map(&:label)).to eq([ "stop", "entry", "collar tight", "collar wide" ])
    expect(chart.lines.map(&:kind)).to eq(%w[ stop entry collar collar ])
    expect(chart.low_label?).to be(false) # the stop's label sits on the bottom edge
    expect(described_class.for(xyz, collar: StopCollar::Collar.refuse("no quote")).lines).to be_empty
    expect(chart.low).to eq(45) # a stop near the bars widens the box below them
    expect(chart.lines.first).to have_attributes(y: chart.plot_bottom, pinned: false)
    far = described_class.for(xyz, entry: 20) # a legacy plug far below the bars is pinned to the edge, not drawn at scale
    expect(far.low).to be > 40
    expect(far.lines.first).to have_attributes(pinned: true, y: far.plot_bottom)
    expect(chart.bars.map(&:x)).to eq(chart.bars.map(&:x).sort)
    expect(chart.bars.last.y_close).to be_between(chart.plot_top, chart.plot_bottom)
    expect(fake.calls.count { |c| c.first == :price_history }).to eq(1)
    described_class.for(xyz)
    expect(fake.calls.count { |c| c.first == :price_history }).to eq(1) # cached for the tools' five minutes
  end

  it "survives one candle and a flat series, and prints every coordinate as a plain number" do
    fake.enqueue(:price_history) { { "candles" => [ { "datetime" => 1.day.ago.to_i * 1000, "open" => 10, "high" => 10, "low" => 10, "close" => 10, "volume" => 1 } ], "symbol" => "XYZ", "empty" => false } }
    one = described_class.for(xyz, stop: 10)
    expect(one.bars.size).to eq(1)
    expect(one.high - one.low).to eq(1)
    expect(one.bars.first.x).to be_between(one.plot_top, one.plot_right)
    Rails.cache.clear
    fake.enqueue(:price_history) { { "candles" => 40.times.map { |i| { "datetime" => (40 - i).days.ago.to_i * 1000, "open" => 10, "high" => 10, "low" => 10, "close" => 10, "volume" => 1 } }, "symbol" => "XYZ", "empty" => false } }
    flat = described_class.for(xyz)
    expect(flat.bars.map(&:y_close).uniq.size).to eq(1)
    values = flat.bars.flat_map { |b| [ b.x, b.y_open, b.y_high, b.y_low, b.y_close ] } + [ flat.bar_width ]
    expect(values).to all(be_a(Float))
    expect(values.map(&:to_s)).to all(match(/\A\d+(\.\d+)?\z/))
  end

  it "draws nothing, and says why, for a delisted instrument, an empty history, and a Schwab failure with nothing cached" do
    xyz.update!(delisted_at: Time.current, delisted_price: 1)
    expect(described_class.for(xyz)).to have_attributes(drawable?: false, reason: "delisted")
    def_ = create(:instrument, symbol: "DEF", cusip: "594918104")
    fake.enqueue(:price_history) { { "candles" => [], "symbol" => "DEF", "empty" => true } }
    expect(described_class.for(def_)).to have_attributes(drawable?: false, reason: "no daily history at Schwab")
    ghi = create(:instrument, symbol: "GHI", cusip: "459200101")
    fake.enqueue(:price_history) { raise Schwab::ServerError.new("down", status: 503) }
    expect(described_class.for(ghi).reason).to start_with("history unavailable")
  end
end
