class Agent::Tools::GetPriceHistory < Agent::Tool
  tool description: "Daily or weekly candles for one symbol over a preset range (1m, 3m, 6m, 1y daily; 2y, 5y weekly), cached five minutes. " \
                    "Candle dates are New York trading days; includes the previous close when Schwab supplies one.",
       input: { symbol: { type: "string", minLength: 1 }, range: { type: "string", enum: Agent::MarketData::RANGES.keys, default: "3m" } },
       required: [ :symbol ],
       output: { symbol: { type: "string" }, range: { type: "string" }, candles: { type: "array", items: { type: "object" } },
                 previous_close: { type: [ "string", "null" ] }, empty: { type: "boolean" }, fetched_at: { type: "string" },
                 stale: { type: "boolean" }, warning: { type: "string" } },
       output_optional: [ :warning ]

  def call(symbol:, range: "3m") = Agent::MarketData.price_history(symbol, range: range)
end
