# One place that reads a year of daily candles for a symbol and says whether they are fit to measure: fresh,
# enough of them, the latest within two trading days. The collar and the trail both stand on this.
class StopCollar::Candles
  MIN_CANDLES = 30
  MAX_TRADING_DAYS_OLD = 2

  Refused = Class.new(StandardError)

  # Sorted symbol-keyed candles, or raises Refused with the reason. A Schwab rate limit propagates: it is a
  # budget spent, not a data quality verdict.
  def self.for(instrument)
    history = Agent::MarketData.price_history(instrument.symbol, range: "1y")
    raise Refused, "history is stale (Schwab unavailable)" if history[:stale]
    candles = Array(history[:candles]).map { |c| c.transform_keys(&:to_sym) }.sort_by { |c| c[:date] }
    raise Refused, "only #{candles.size} daily candles; #{MIN_CANDLES} needed" if candles.size < MIN_CANDLES
    raise Refused, "latest candle is #{candles.last[:date]}, more than #{MAX_TRADING_DAYS_OLD} trading days old" if candles.last[:date].to_date < oldest_acceptable_date
    new(candles)
  end

  # Two trading days back, counting weekdays and any known closed day.
  def self.oldest_acceptable_date
    date = MarketDay.today
    MAX_TRADING_DAYS_OLD.times do
      date -= 1
      date -= 1 while date.on_weekend? || MarketDay.find_by(date: date)&.trading == false
    end
    date
  end

  attr_reader :all

  def initialize(candles) = @all = candles

  def last(n) = all.last(n)
  def close = all.last[:close]

  # Average true range over the last n bars, the plain average form.
  def atr(n)
    ranges = all.each_cons(2).to_a.last(n).map { |prev, c| [ c[:high] - c[:low], (c[:high] - prev[:close]).abs, (c[:low] - prev[:close]).abs ].max }
    ranges.sum / ranges.size
  end
end
