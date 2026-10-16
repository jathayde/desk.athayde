# One instrument's rolling correlation of daily returns with SPY (PRD §5.12.5), so the Sunday review can say when a
# diversifier has stopped diversifying. SPY is the benchmark series only, never a row of its own. Diagnostic only.
class Correlation < ApplicationRecord
  BENCHMARK = "SPY"
  MAX_GAP_DAYS = 5 # calendar days between shared closes: a long weekend, not a hole in the history
  SPLIT_MOVE = BigDecimal("0.35") # a one-day move this large is more likely an unadjusted split than a return

  Measure = Data.define(:value, :last_close_on, :reason)

  belongs_to :instrument

  # Pearson correlation of the two series' daily returns over the last window shared closes, or the reason there
  # is none: too few closes, a series that stopped before the benchmark, a gap, a split-sized move, or no variance.
  def self.measure(closes, benchmark, window:)
    return refuse("history ends #{closes.keys.max}") if closes.keys.max < benchmark.keys.max
    dates = (closes.keys & benchmark.keys).sort.last(window + 1)
    return refuse("fewer than #{window + 1} shared closes") if dates.size < window + 1
    return refuse("gap in history") if dates.each_cons(2).any? { |prev, day| (day - prev).to_i > MAX_GAP_DAYS }
    a, b = [ closes, benchmark ].map { |series| dates.each_cons(2).map { |prev, day| series[day] / series[prev] - 1 } }
    return refuse("possible split in window") if (a + b).any? { it.abs > SPLIT_MOVE }
    mean_a, mean_b = a.sum / a.size, b.sum / b.size
    spread = Math.sqrt(a.sum { (it - mean_a)**2 } * b.sum { (it - mean_b)**2 })
    return refuse("no variance in window") if spread.zero?
    Measure.new(value: (a.zip(b).sum { |x, y| (x - mean_a) * (y - mean_b) } / spread).clamp(-1, 1).round(6), last_close_on: dates.last, reason: nil)
  end

  def self.refuse(reason) = Measure.new(value: nil, last_close_on: nil, reason: reason)
  private_class_method :refuse

  def diversifier? = instrument.tagged?("diversifier")
end
