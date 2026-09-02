# The agent-facing surface: one tool registry, two transports (MCP for the Claude app, in-process for
# the scheduled runtime). See docs/phase-1-plan.md §3.
module Agent
  MODEL = "claude-sonnet-5" # synthesis over structured data; see Agent::Pricing for what it costs
  REQUEST_TIMEOUT = 120 # seconds per call; the SDK default of ten minutes would outlive the run's own deadline
  MAX_RETRIES = 2

  def self.fake? = Rails.configuration.x.agent.adapter == :fake

  # One client per process. The key is passed explicitly: the SDK would otherwise read an environment variable.
  def self.client
    return FakeAnthropic.instance if fake?
    @client ||= Anthropic::Client.new(api_key: Rails.application.credentials.dig(:anthropic, :api_key).presence || raise(NotConfigured, "anthropic.api_key is not in credentials"),
                                      timeout: REQUEST_TIMEOUT, max_retries: MAX_RETRIES)
  end

  class NotConfigured < StandardError; end

  # Decimal strings for money and quantities, ISO 8601 New York timestamps, nothing else touched.
  def self.serialize(value)
    case value
    when BigDecimal then value.to_s("F")
    when ActiveSupport::TimeWithZone, Time then value.in_time_zone(MarketDay::ZONE).iso8601
    when Date then value.iso8601
    when Symbol then value.to_s
    when Hash then value.to_h { |k, v| [ k.to_s, serialize(v) ] }
    when Array then value.map { |v| serialize(v) }
    else value
    end
  end
end
