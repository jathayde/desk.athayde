module Schwab
  Candle = Data.define(:date, :time, :open, :high, :low, :close, :volume) do
    def self.from(raw)
      new(date: Timestamp.candle_date(raw["datetime"]), time: Timestamp.parse(raw["datetime"]),
          open: Decimal.parse(raw["open"]), high: Decimal.parse(raw["high"]), low: Decimal.parse(raw["low"]),
          close: Decimal.parse(raw["close"]), volume: raw["volume"])
    end
  end

  PriceHistory = Data.define(:symbol, :candles, :previous_close, :empty, :raw) do
    def self.from(raw)
      new(symbol: raw["symbol"], candles: Array(raw["candles"]).map { |c| Candle.from(c) },
          previous_close: Decimal.parse(raw["previousClose"]), empty: raw["empty"] == true, raw: raw)
    end

    def empty? = empty
  end
end
