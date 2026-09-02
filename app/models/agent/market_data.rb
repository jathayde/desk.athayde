# Quotes and price history for the tools, cached beyond their freshness window so a Schwab failure can
# still answer with the last known value marked stale. Draws on a ceiling below the shared Schwab budget so a
# chatty session cannot starve sync.
module Agent::MarketData
  QUOTE_FRESH = 2.minutes
  HISTORY_FRESH = 5.minutes
  # Entries hold BigDecimal, TimeWithZone, and symbol keys: fine under the default Marshal serializer,
  # not under message_pack.
  KEEP = 12.hours
  BUDGET_CEILING = 70
  RANGES = {
    "1m" => [ :month, 1, :daily ], "3m" => [ :month, 3, :daily ], "6m" => [ :month, 6, :daily ],
    "1y" => [ :year, 1, :daily ], "2y" => [ :year, 2, :weekly ], "5y" => [ :year, 5, :weekly ]
  }.freeze

  Fetch = Data.define(:quotes, :invalid_symbols, :error)

  def self.quotes(symbols)
    symbols = symbols.map { |s| s.to_s.strip.upcase }.reject(&:blank?).uniq
    cutoff = QUOTE_FRESH.ago
    cached = Rails.cache.read_multi(*symbols.map { |s| quote_key(s) })
    missing = symbols.reject { |s| cached[quote_key(s)]&.dig(:fetched_at)&.>(cutoff) }
    fetch = fetch_quotes(missing)
    quotes = symbols.filter_map do |symbol|
      entry = fetch.quotes[symbol] || cached[quote_key(symbol)]
      entry && entry.merge(stale: entry[:fetched_at] <= cutoff)
    end
    raise fetch.error if fetch.error && quotes.empty? # nothing cached to degrade to: the failure is the answer
    unavailable = missing - fetch.quotes.keys - fetch.invalid_symbols - quotes.map { |q| q[:symbol] }
    warning = fetch.error && "Schwab unavailable (#{fetch.error.message}); cached values shown where they exist"
    { quotes: quotes, invalid_symbols: fetch.invalid_symbols, unavailable_symbols: unavailable, warning: warning }
  end

  def self.price_history(symbol, range:)
    symbol = symbol.to_s.strip.upcase
    key = "agent:history:#{symbol}:#{range}"
    entry = Rails.cache.read(key)
    return entry.merge(stale: false) if entry && entry[:fetched_at] > HISTORY_FRESH.ago
    period_type, period, frequency_type = RANGES.fetch(range.to_s) { raise Agent::Tool::InvalidArguments, "range must be one of #{RANGES.keys.join(', ')}" }
    begin
      history = Schwab::PriceHistory.from(client.price_history(symbol, period_type: period_type, period: period, frequency_type: frequency_type))
      fresh = { symbol: symbol, range: range, candles: history.candles.map(&:to_h), previous_close: history.previous_close, empty: history.empty?, fetched_at: Time.current }
      Rails.cache.write(key, fresh, expires_in: KEEP)
      fresh.merge(stale: false)
    rescue Schwab::RateLimited
      raise # a rate limit is a tool error carrying retry_after, never a degraded answer
    rescue Schwab::Error => e
      raise e unless entry
      entry.merge(stale: true, warning: "Schwab unavailable (#{e.message}); last fetched #{entry[:fetched_at].iso8601}")
    end
  end

  class << self
    private
      def client = Schwab.client(wait: false, budget: BUDGET_CEILING)
      def quote_key(symbol) = "agent:quote:#{symbol}"

      def fetch_quotes(symbols)
        return Fetch.new({}, [], nil) if symbols.empty?
        batch = Schwab::Quote.batch(client.quotes(symbols))
        now = Time.current
        quotes = batch.quotes.to_h do |q|
          entry = { symbol: q.symbol, cusip: q.cusip, last: q.last, bid: q.bid, ask: q.ask, mark: q.mark, net_change: q.net_change,
                    net_percent_change: q.net_percent_change, quote_time: q.quote_time, trade_time: q.trade_time, fetched_at: now }
          Rails.cache.write(quote_key(q.symbol), entry, expires_in: KEEP)
          [ q.symbol, entry ]
        end
        Fetch.new(quotes, batch.invalid_symbols, nil)
      rescue Schwab::RateLimited
        raise # a rate limit is a tool error carrying retry_after, never a degraded answer
      rescue Schwab::Error => e
        Fetch.new({}, [], e)
      end
  end
end
