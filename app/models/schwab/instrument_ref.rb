module Schwab
  # The instrument block that appears on positions, order legs, transfer items, and quotes.
  # nil when the block is absent (container orders with no legs).
  InstrumentRef = Data.define(:symbol, :cusip, :instrument_id, :asset_type, :description) do
    def self.from(raw)
      return nil if raw.blank?
      new(symbol: raw["symbol"], cusip: raw["cusip"].presence, instrument_id: raw["instrumentId"],
          asset_type: raw["assetType"], description: raw["description"])
    end

    def currency? = asset_type == "CURRENCY"
  end
end
