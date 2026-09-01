# Everything that knows a Schwab field name lives under this namespace. See docs/schwab-api-contract.md.
module Schwab
  LOOKBACK = 60.days # orders and transactions; SCHWAB_SHAPE_UNVERIFIED (one source says a year)
  RATE_BUDGET_PER_MINUTE = 100 # community figure is 120/min per app; SCHWAB_SHAPE_UNVERIFIED
  QUOTE_BATCH = 100 # SCHWAB_SHAPE_UNVERIFIED

  def self.client(token: nil)
    case Rails.configuration.x.schwab.adapter
    when :fake then FakeClient.instance
    else Client.new(token: token || SchwabToken.current)
    end
  end

  def self.app_key = Rails.application.credentials.dig(:schwab, :app_key)
  def self.app_secret = Rails.application.credentials.dig(:schwab, :app_secret)
  def self.callback_url = ENV.fetch("SCHWAB_CALLBACK_URL")
end
