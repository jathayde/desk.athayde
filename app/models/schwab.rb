# Everything that knows a Schwab field name lives under this namespace. See docs/schwab-api-contract.md.
module Schwab
  LOOKBACK = 60.days # orders and transactions; SCHWAB_SHAPE_UNVERIFIED (one source says a year)
  RATE_BUDGET_PER_MINUTE = 100 # community figure is 120/min per app; SCHWAB_SHAPE_UNVERIFIED
  QUOTE_BATCH = 100 # SCHWAB_SHAPE_UNVERIFIED

  class NoUsableToken < Error; end

  # Anything a client needs from a token: a bearer string. SchwabToken rows satisfy it; so does this for a
  # token that has no row yet.
  BearerToken = Data.define(:access_token)

  def self.fake? = Rails.configuration.x.schwab.adapter == :fake

  def self.client(token: nil, wait: true)
    return FakeClient.instance if fake?
    Client.new(token: token || usable_token!, wait: wait)
  end

  # The three-legged flow and the refresh grant authenticate with the app key, not a bearer token.
  def self.oauth_client(wait: true) = fake? ? FakeClient.instance : Client.new(wait: wait)

  def self.usable_token!
    SchwabToken.current.tap do |token|
      raise NoUsableToken, "no usable Schwab token; re-authenticate" unless token&.usable?
    end
  end

  def self.app_key = Rails.application.credentials.dig(:schwab, :app_key)
  def self.app_secret = Rails.application.credentials.dig(:schwab, :app_secret)
  # Production reads exactly this dokku config var; elsewhere the app's own route serves as the fake callback.
  def self.callback_url
    ENV.fetch("SCHWAB_CALLBACK_URL") do
      raise KeyError, "SCHWAB_CALLBACK_URL is not set" if Rails.env.production?
      Rails.application.routes.url_helpers.schwab_callback_url
    end
  end
end
