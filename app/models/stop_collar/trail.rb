# Trailing stops for a protected position (PRD §5.4.1): the chandelier exit and the ATR trail off the latest
# close, from the same candles the collar reads, under the same gates. The suggestion is the tightest trail
# that sits below the latest close and above the working stop; never placed, only shown. A rate limit
# propagates so the job stops rather than wiping what it knew.
class StopCollar::Trail
  Suggestion = Data.define(:strategy, :price)

  def initialize(position, params: {})
    @position, @params = position, StopCollar::Calculator::DEFAULTS.merge(params.to_h.transform_keys(&:to_s))
  end

  def suggestion
    return nil unless @position.stop_price # nothing to tighten; the unprotected alert owns that position
    candles = StopCollar::Candles.for(@position.instrument)
    trails = {
      chandelier: candles.last(param(:chandelier_bars).to_i).map { |c| c[:high] }.max - param(:chandelier_k) * candles.atr(param(:chandelier_bars).to_i),
      atr: candles.close - param(:atr_k) * candles.atr(14)
    }.transform_values { |v| v.round(4) }
    ceiling = [ candles.close, @position.last_price ].compact.min
    strategy, price = trails.select { |_, v| v < ceiling && v > @position.stop_price }.max_by { |_, v| v }
    price && Suggestion.new(strategy: strategy.to_s, price: price)
  rescue StopCollar::Candles::Refused
    nil
  end

  private
    def param(name) = BigDecimal(@params.fetch(name.to_s).to_s)
end
