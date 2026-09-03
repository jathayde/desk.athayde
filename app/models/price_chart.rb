# The candles behind a stop decision, ready to draw: the last months of daily bars from the cached history,
# scaled to one SVG box, with the lines the reader compares them against (the working stop, the average
# entry, today's collar). A page never waits on Schwab for this: the cache answers, stale if it must, and a
# desk without history says so instead of drawing.
class PriceChart
  WIDTH = 480 # user units: a phone shows the box near 1:1, a desktop a little larger, so the type reads on both
  HEIGHT = 240
  PAD = { top: 14, right: 74, bottom: 22, left: 6 }.freeze
  RANGE = "1y" # the collar's own range, so a review page reads one cache entry for both
  BARS = 90
  REACH = BigDecimal("0.35") # a mark this far outside the bars' range still stretches the box; farther is pinned to the edge
  LABEL_CLEARANCE = 10 # user units between an axis label and a mark's label before the axis label yields

  Bar = Data.define(:date, :open, :high, :low, :close, :x, :y_open, :y_high, :y_low, :y_close) do
    def up? = close >= open
  end
  Line = Data.define(:label, :price, :y, :kind, :pinned)

  attr_reader :symbol, :bars, :lines, :reason, :stale, :as_of, :bar_width, :low, :high

  def self.for(instrument, stop: nil, entry: nil, collar: nil)
    return new(instrument.symbol, [], reason: "delisted") if instrument.delisted?
    history = Agent::MarketData.price_history(instrument.symbol, range: RANGE)
    candles = Array(history[:candles]).map { |c| c.transform_keys(&:to_sym) }.sort_by { |c| c[:date] }.last(BARS)
    return new(instrument.symbol, [], reason: "no daily history at Schwab") if candles.empty?
    new(instrument.symbol, candles, stop: stop, entry: entry, collar: collar&.presentable, stale: history[:stale], as_of: history[:fetched_at])
  rescue Schwab::RateLimited, Schwab::Error, Agent::Tool::InvalidArguments => e
    new(instrument.symbol, [], reason: "history unavailable (#{e.message.truncate(80)})")
  end

  def initialize(symbol, candles, stop: nil, entry: nil, collar: nil, reason: nil, stale: false, as_of: nil)
    @symbol, @reason, @stale, @as_of = symbol, reason, stale, as_of
    @bars, @lines = [], []
    return if candles.empty?
    marks = marks_for(stop: stop, entry: entry, collar: collar)
    @low, @high = axis_range(candles, marks.map(&:price))
    @bars, @bar_width = plot_bars(candles)
    @lines = marks.map { |m| Line.new(label: m.label, price: m.price, y: y(m.price.clamp(@low, @high)), kind: m.kind, pinned: !m.price.between?(@low, @high)) }
  end

  def drawable? = bars.any?
  def width = WIDTH
  def height = HEIGHT
  def plot_top = PAD[:top]
  def plot_bottom = HEIGHT - PAD[:bottom]
  def plot_right = WIDTH - PAD[:right]
  def first_date = bars.first.date
  def last_date = bars.last.date
  def last_close = bars.last.close

  # The axis labels yield to a mark's label sitting on the same edge.
  def high_label? = lines.none? { |l| (l.y - plot_top).abs < LABEL_CLEARANCE }
  def low_label? = lines.none? { |l| (l.y - plot_bottom).abs < LABEL_CLEARANCE }

  # Where a price sits on the box: a decimal in, a plain float out, since a BigDecimal prints as 0.116e3 in an attribute.
  def y(price) = (plot_bottom - (price.to_d - @low) / (@high - @low) * (plot_bottom - plot_top)).to_f.round(1)

  private
    Mark = Data.define(:label, :kind, :price)

    def marks_for(stop:, entry:, collar:)
      [ [ "stop", "stop", stop ], [ "entry", "entry", entry ], [ "collar tight", "collar", collar&.tight ], [ "collar wide", "collar", collar&.wide ] ]
        .reject { |_, _, price| price.nil? }.map { |label, kind, price| Mark.new(label: label, kind: kind, price: price.to_d) }
    end

    # The bars' own range, stretched by any mark within reach; a flat series gets a unit of height.
    def axis_range(candles, mark_prices)
      bar_low, bar_high = candles.map { |c| c[:low].to_d }.min, candles.map { |c| c[:high].to_d }.max
      reach = [ (bar_high - bar_low) * REACH, bar_high * BigDecimal("0.01") ].max
      within = mark_prices.select { |price| price.between?(bar_low - reach, bar_high + reach) }
      low, high = ([ bar_low ] + within).min, ([ bar_high ] + within).max
      [ low, high == low ? high + 1 : high ]
    end

    def plot_bars(candles)
      step = (plot_right - PAD[:left]).to_d / candles.size
      bars = candles.each_with_index.map do |c, i|
        Bar.new(date: c[:date].to_date, open: c[:open].to_d, high: c[:high].to_d, low: c[:low].to_d, close: c[:close].to_d,
                x: (PAD[:left] + step * i + step / 2).to_f.round(1), y_open: y(c[:open]), y_high: y(c[:high]), y_low: y(c[:low]), y_close: y(c[:close]))
      end
      [ bars, [ (step * 0.6).to_f.round(1), 1.0 ].max ]
    end
end
