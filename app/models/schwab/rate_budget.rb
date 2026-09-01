module Schwab
  # One request budget shared by every process (Puma and the worker) through the cache store.
  # Exceeding it raises rather than sleeping so a web request never blocks on the worker.
  module RateBudget
    def self.take!(now: ::Time.current, budget: Schwab::RATE_BUDGET_PER_MINUTE)
      key = "schwab:rate:#{now.to_i / 60}"
      Rails.cache.write(key, 0, expires_in: 2.minutes, unless_exist: true)
      count = Rails.cache.increment(key, 1, expires_in: 2.minutes)
      return if count.nil? || count <= budget # a cache hiccup fails open; the API's own limit still applies
      raise RateLimited.new("Local Schwab rate budget spent (#{budget}/min)", retry_after: 60 - now.sec)
    end
  end
end
