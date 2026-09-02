# Where a stop may sit (PRD §5.4.1): several standard methods over Schwab's daily history, bounded by the
# percent stop as a floor. Data that cannot support the methods is a refusal, never a guess.
module StopCollar
  Collar = Data.define(:methods, :tight, :wide, :floor, :floor_dominates, :quality, :refusal) do
    # The frozen jsonb back as the object: decimals as decimals, the quality a symbol.
    def self.load(hash)
      hash = hash.to_h
      new(methods: hash["methods"] || {}, tight: decimal(hash["tight"]), wide: decimal(hash["wide"]), floor: decimal(hash["floor"]),
          floor_dominates: hash["floor_dominates"] == true, quality: hash["quality"]&.to_sym, refusal: hash["refusal"])
    end

    def self.decimal(value) = value.nil? ? nil : BigDecimal(value.to_s)
    private_class_method :decimal

    def ok? = quality == :ok
    def to_h = Agent.serialize(super)
  end
end
