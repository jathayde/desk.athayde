module Schwab
  Position = Data.define(:instrument, :quantity, :average_price, :market_value, :cost_basis, :raw) do
    def cash_equivalent? = instrument&.asset_type == "CASH_EQUIVALENT"

    def self.from(raw)
      quantity = Decimal.parse_or_zero(raw["longQuantity"]) - Decimal.parse_or_zero(raw["shortQuantity"])
      new(instrument: InstrumentRef.from(raw.fetch("instrument") { raise MappingError, "position without instrument" }),
          quantity: quantity, average_price: Decimal.parse(raw["averagePrice"]), market_value: Decimal.parse(raw["marketValue"]),
          cost_basis: Decimal.parse(raw["averagePrice"])&.*(quantity), raw: raw)
    end
  end
end
