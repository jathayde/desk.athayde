# One year of daily candles and a fresh quote in, a Collar out. Methods, each a stop price for a long entry:
# ATR multiple (entry − k × ATR14), swing low (lowest low of N bars − buffer × ATR14), percent (entry × (1 − p)),
# and chandelier (highest high of M bars − k × ATR(M)), computed for reference. tight and wide are the highest
# and lowest of the ATR and swing stops; the percent stop is the floor under wide, and when it is tighter than
# both methods it is the collar's only edge (floor_dominates), with the entry as the ceiling.
class StopCollar::Calculator
  MIN_CANDLES = 30
  MAX_TRADING_DAYS_OLD = 2
  DEFAULTS = { "atr_k" => "2.5", "swing_bars" => "10", "swing_buffer_atr" => "0.2", "percent" => "8", "chandelier_bars" => "22", "chandelier_k" => "3" }.freeze

  def initialize(instrument, entry_price:, params: {})
    @instrument, @entry, @params = instrument, BigDecimal(entry_price.to_s), DEFAULTS.merge(params.to_h.transform_keys(&:to_s))
  end

  def call
    history = Agent::MarketData.price_history(@instrument.symbol, range: "1y")
    return refuse("history is stale (Schwab unavailable)") if history[:stale]
    candles = Array(history[:candles]).map { |c| c.transform_keys(&:to_sym) }.sort_by { |c| c[:date] }
    return refuse("only #{candles.size} daily candles; #{MIN_CANDLES} needed") if candles.size < MIN_CANDLES
    return refuse("latest candle is #{candles.last[:date]}, more than #{MAX_TRADING_DAYS_OLD} trading days old") if candles.last[:date].to_date < oldest_acceptable_date
    quote = Agent::MarketData.quotes([ @instrument.symbol ])[:quotes].first
    return refuse("no fresh quote") if quote.nil? || quote[:stale]

    atr14 = atr(candles, 14)
    methods = {
      atr: @entry - param(:atr_k) * atr14,
      swing: candles.last(param(:swing_bars).to_i).map { |c| c[:low] }.min - param(:swing_buffer_atr) * atr14,
      percent: @entry * (1 - param(:percent) / 100),
      chandelier: candles.last(param(:chandelier_bars).to_i).map { |c| c[:high] }.max - param(:chandelier_k) * atr(candles, param(:chandelier_bars).to_i)
    }.transform_values { |v| v.round(4) }
    candidates = methods.values_at(:atr, :swing).select { |v| v < @entry }
    return refuse("the ATR and swing stops land at or above the entry") if candidates.empty?
    floor = methods[:percent]
    tight, wide = candidates.max, [ candidates.min, floor ].max
    floor_dominates = tight < floor
    StopCollar::Collar.new(methods: methods, tight: floor_dominates ? floor : tight, wide: floor_dominates ? floor : wide, floor: floor, floor_dominates: floor_dominates, quality: :ok, refusal: nil)
  rescue Schwab::Error, Agent::Tool::InvalidArguments => e
    refuse("market data unavailable: #{e.message}")
  end

  private
    def param(name) = BigDecimal(@params.fetch(name.to_s).to_s)
    def refuse(reason) = StopCollar::Collar.new(methods: {}, tight: nil, wide: nil, floor: nil, floor_dominates: false, quality: :refused, refusal: reason)

    # Two trading days back, counting weekdays and any known closed day.
    def oldest_acceptable_date
      date = MarketDay.today
      MAX_TRADING_DAYS_OLD.times do
        date -= 1
        date -= 1 while date.on_weekend? || MarketDay.find_by(date: date)&.trading == false
      end
      date
    end

    # Average true range over the last n bars, the plain average form.
    def atr(candles, n)
      ranges = candles.each_cons(2).to_a.last(n).map do |prev, c|
        [ c[:high] - c[:low], (c[:high] - prev[:close]).abs, (c[:low] - prev[:close]).abs ].max
      end
      ranges.sum / ranges.size
    end
end
