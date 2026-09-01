module Schwab
  Position = Data.define(:instrument, :quantity, :average_price, :market_value, :raw) do
    def self.from(raw)
      quantity = Decimal.parse_or_zero(raw["longQuantity"]) - Decimal.parse_or_zero(raw["shortQuantity"])
      new(instrument: InstrumentRef.from(raw.fetch("instrument") { raise MappingError, "position without instrument" }),
          quantity: quantity, average_price: Decimal.parse(raw["averagePrice"]), market_value: Decimal.parse(raw["marketValue"]), raw: raw)
    end
  end
end
