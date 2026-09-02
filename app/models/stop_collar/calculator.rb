# A year of daily candles and a fresh quote in, a Collar out. Methods, each a stop price for a long entry:
# ATR multiple (entry − k × ATR14), swing low (lowest low of N bars − buffer × ATR14), percent (entry × (1 − p)),
# and chandelier (highest high of M bars − k × ATR(M)), computed for reference. tight and wide are the highest
# and lowest of the ATR and swing stops; the percent stop is the floor under wide, and when it is tighter than
# both methods it is the collar's only edge (floor_dominates), with the entry as the ceiling.
class StopCollar::Calculator
  DEFAULTS = { "atr_k" => "2.5", "swing_bars" => "10", "swing_buffer_atr" => "0.2", "percent" => "8", "chandelier_bars" => "22", "chandelier_k" => "3" }.freeze

  def initialize(instrument, entry_price:, params: {})
    @instrument, @entry, @params = instrument, BigDecimal(entry_price.to_s), DEFAULTS.merge(params.to_h.transform_keys(&:to_s))
  end

  def call
    candles = StopCollar::Candles.for(@instrument)
    quote = Agent::MarketData.quotes([ @instrument.symbol ])[:quotes].first
    return refuse("no fresh quote") if quote.nil? || quote[:stale]

    atr14 = candles.atr(14)
    methods = {
      atr: @entry - param(:atr_k) * atr14,
      swing: candles.last(param(:swing_bars).to_i).map { |c| c[:low] }.min - param(:swing_buffer_atr) * atr14,
      percent: @entry * (1 - param(:percent) / 100),
      chandelier: candles.last(param(:chandelier_bars).to_i).map { |c| c[:high] }.max - param(:chandelier_k) * candles.atr(param(:chandelier_bars).to_i)
    }.transform_values { |v| v.round(4) }
    candidates = methods.values_at(:atr, :swing).select { |v| v < @entry }
    return refuse("the ATR and swing stops land at or above the entry") if candidates.empty?
    floor = methods[:percent]
    tight, wide = candidates.max, [ candidates.min, floor ].max
    floor_dominates = tight < floor
    StopCollar::Collar.new(methods: methods, tight: floor_dominates ? floor : tight, wide: floor_dominates ? floor : wide, floor: floor, floor_dominates: floor_dominates, quality: :ok, refusal: nil)
  rescue StopCollar::Candles::Refused => e
    refuse(e.message)
  rescue Schwab::RateLimited
    raise # a budget spent is not a verdict on the stop
  rescue Schwab::Error, Agent::Tool::InvalidArguments => e
    refuse("market data unavailable: #{e.message}")
  end

  private
    def param(name) = BigDecimal(@params.fetch(name.to_s).to_s)
    def refuse(reason) = StopCollar::Collar.new(methods: {}, tight: nil, wide: nil, floor: nil, floor_dominates: false, quality: :refused, refusal: reason)
end
