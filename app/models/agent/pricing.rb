# Dollars per million tokens by model id. An unknown model prices to nil, shown as "unpriced", never zero.
module Agent::Pricing
  RATES = {
    "claude-sonnet-5" => { input: 2.0, output: 10.0 },
    "claude-opus-5" => { input: 5.0, output: 25.0 }
  }.freeze
  CACHE_WRITE = 1.25
  CACHE_READ = 0.10

  def self.cost(model, input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
    rates = RATES[model.to_s] or return nil
    dollars = (input_tokens.to_i * rates[:input]) + (cache_creation_input_tokens.to_i * rates[:input] * CACHE_WRITE) +
              (cache_read_input_tokens.to_i * rates[:input] * CACHE_READ) + (output_tokens.to_i * rates[:output])
    (BigDecimal(dollars.to_s) / 1_000_000).round(4)
  end
end
