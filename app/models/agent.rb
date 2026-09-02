# The agent-facing surface: one tool registry, two transports (MCP for the Claude app, in-process for
# the scheduled runtime). See docs/phase-1-plan.md §3.
module Agent
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
