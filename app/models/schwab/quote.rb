module Schwab
  class Quote < Data.define(:symbol, :cusip, :asset_main_type, :last, :bid, :ask, :mark, :net_change, :net_percent_change,
                            :quote_time, :trade_time, :raw)
    Batch = Data.define(:quotes, :invalid_symbols)

    # Each page is keyed by symbol, with unknown symbols reported under "errors" in the same 200.
    def self.batch(pages)
      pages = Array.wrap(pages)
      Batch.new(quotes: pages.flat_map { |page| page.except("errors").map { |symbol, body| from(symbol, body) } },
                invalid_symbols: pages.flat_map { |page| Array(page.dig("errors", "invalidSymbols")) })
    end

    def self.from(symbol, raw)
      q = raw["quote"] || {}
      new(symbol: raw["symbol"] || symbol, cusip: raw.dig("reference", "cusip"), asset_main_type: raw["assetMainType"],
          last: Decimal.parse(q["lastPrice"]), bid: Decimal.parse(q["bidPrice"]), ask: Decimal.parse(q["askPrice"]),
          mark: Decimal.parse(q["mark"]), net_change: Decimal.parse(q["netChange"]), net_percent_change: Decimal.parse(q["netPercentChange"]),
          quote_time: Timestamp.parse(q["quoteTime"]), trade_time: Timestamp.parse(q["tradeTime"]), raw: raw)
    end
  end
end
