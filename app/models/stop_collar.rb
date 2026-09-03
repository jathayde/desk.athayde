# Where a stop may sit (PRD §5.4.1): several standard methods over Schwab's daily history, bounded by the
# percent stop as a floor. Data that cannot support the methods is a refusal, never a guess.
module StopCollar
  # Today's collar for a page: the same calculator the proposals use, from the position's last price, with a
  # Schwab failure or a spent budget answering as a refusal the page can print rather than a 500.
  def self.today(instrument, from:, setup: nil)
    return nil if from.nil? || instrument.delisted?
    Calculator.new(instrument, entry_price: from, params: RiskRule.params_for("stop_collar", setup: setup)).call
  rescue Schwab::RateLimited, Schwab::Error => e
    Collar.refuse("Schwab unavailable (#{e.message.truncate(80)})")
  end

  Collar = Data.define(:methods, :tight, :wide, :floor, :floor_dominates, :quality, :refusal) do
    # The frozen jsonb back as the object: decimals as decimals, the quality a symbol.
    def self.load(hash)
      hash = hash.to_h
      new(methods: hash["methods"] || {}, tight: decimal(hash["tight"]), wide: decimal(hash["wide"]), floor: decimal(hash["floor"]),
          floor_dominates: hash["floor_dominates"] == true, quality: hash["quality"]&.to_sym, refusal: hash["refusal"])
    end

    def self.refuse(reason) = new(methods: {}, tight: nil, wide: nil, floor: nil, floor_dominates: false, quality: :refused, refusal: reason)
    def self.decimal(value) = value.nil? ? nil : BigDecimal(value.to_s)
    private_class_method :decimal

    def ok? = quality == :ok
    def presentable = ok? ? self : nil # a refused collar has no lines to draw
    def to_h = Agent.serialize(super)
  end
end
