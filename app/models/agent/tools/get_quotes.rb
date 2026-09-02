class Agent::Tools::GetQuotes < Agent::Tool
  MAX_SYMBOLS = 50

  tool description: "Live quotes for up to 50 symbols from Schwab, cached for two minutes. Unknown symbols are listed in invalid_symbols. " \
                    "When Schwab is unavailable the last cached quote is returned with stale: true and a warning; symbols with no cached " \
                    "quote are listed in unavailable_symbols.",
       input: { symbols: { type: "array", items: { type: "string" }, minItems: 1, maxItems: MAX_SYMBOLS, description: "Ticker symbols" } },
       required: [ :symbols ],
       output: { quotes: { type: "array", items: { type: "object" } }, invalid_symbols: { type: "array", items: { type: "string" } },
                 unavailable_symbols: { type: "array", items: { type: "string" } }, warning: { type: [ "string", "null" ] } }

  def call(symbols:)
    symbols = symbols.map { |s| s.to_s.strip.upcase }.reject(&:blank?).uniq
    raise InvalidArguments, "symbols must be 1 to #{MAX_SYMBOLS} tickers" unless symbols.size.between?(1, MAX_SYMBOLS)
    Agent::MarketData.quotes(symbols)
  end
end
