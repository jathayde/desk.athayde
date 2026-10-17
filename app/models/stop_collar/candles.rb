# One place that reads a year of daily candles for a symbol and says whether they are fit to measure: fresh,
# enough of them, the latest within two trading days. The collar and the trail both stand on this.
class StopCollar::Candles
  MIN_CANDLES = 30
  MAX_TRADING_DAYS_OLD = 2

  Refused = Class.new(StandardError)

  # Sorted symbol-keyed candles, enough of them to measure a collar, or raises Refused with the reason. A Schwab
  # rate limit propagates: it is a budget spent, not a data quality verdict.
  def self.for(instrument) = read(instrument.symbol, at_least: MIN_CANDLES)

  # A year of a symbol's daily candles, fresh and recent, at least at_least of them: the one read the collar, the
  # forecast's reference close, and the decision snapshot share. Raises Refused with the reason.
  def self.read(symbol, at_least: 1)
    history = Agent::MarketData.price_history(symbol, range: "1y")
    raise Refused, "history is stale (Schwab unavailable)" if history[:stale]
    candles = Array(history[:candles]).map { |c| c.transform_keys(&:to_sym) }.sort_by { |c| c[:date] }
    raise Refused, "only #{candles.size} daily candles; #{at_least} needed" if candles.size < at_least
    raise Refused, "latest candle is #{candles.last[:date]}, more than #{MAX_TRADING_DAYS_OLD} trading days old" if candles.last[:date].to_date < oldest_acceptable_date
    new(candles, fetched_at: history[:fetched_at])
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

  attr_reader :all, :fetched_at

  def initialize(candles, fetched_at: nil)
    @all, @fetched_at = candles, fetched_at
  end

  SETTLE = 15.minutes # after the regular close, before a fetched daily bar is taken as the session's final one

  # The candles whose session had closed when they were fetched: today's is a partial bar unless the history was
  # fetched SETTLE after its regular close, by the stored calendar (never fetched; unknown means not yet). The
  # fetch time, not the clock: a history cached at 15:58 still holds the 15:58 bar at 16:05.
  def self.final(candles, fetched_at:)
    today = fetched_at.in_time_zone(MarketDay::ZONE).to_date
    closes_at = MarketDay.find_by(date: today)&.regular_closes_at
    settled = closes_at && closes_at + SETTLE <= fetched_at
    candles.select { |c| c[:date].to_date < today || (settled && c[:date].to_date == today) }
  end

  def last(n) = all.last(n)
  def close = all.last[:close]
  def final = self.class.final(all, fetched_at: fetched_at || Time.current)

  # Average true range over the last n bars, the plain average form.
  def atr(n)
    ranges = all.each_cons(2).to_a.last(n).map { |prev, c| [ c[:high] - c[:low], (c[:high] - prev[:close]).abs, (c[:low] - prev[:close]).abs ].max }
    ranges.sum / ranges.size
  end
end
