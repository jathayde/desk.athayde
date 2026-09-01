module Schwab
  # Plaintext account numbers arrive in the body of every Trader API response. They are removed
  # here, in the client, before any body reaches raw columns, cassettes, or logs.
  module Scrub
    REDACTED_KEYS = %w[ accountNumber user ].freeze
    ACCOUNT_HASH = /[0-9A-F]{64}/i
    LONG_DIGIT_RUN = /\b\d{8,}\b/

    def self.json(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), h| h[k] = REDACTED_KEYS.include?(k) ? nil : json(v) }
      when Array then value.map { |v| json(v) }
      else value
      end
    end

    # JSON bodies are scrubbed by key; anything else (gateway HTML) loses long digit runs, which is
    # the shape an account number would take in prose.
    def self.body(text)
      return text if text.blank?
      parsed = JSON.parse(text) rescue (return text.gsub(LONG_DIGIT_RUN, "<REDACTED>"))
      JSON.generate(json(parsed))
    end

    # Log lines carry the route template, never the account hash.
    def self.path(path) = path.gsub(ACCOUNT_HASH, "{hash}")
  end
end
