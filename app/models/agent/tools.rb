# The registry and the one dispatch entry point every transport uses.
module Agent::Tools
  Result = Data.define(:value, :error, :retry_after) do
    def self.success(value) = new(value: value, error: nil, retry_after: nil)
    def self.failure(error, retry_after: nil) = new(value: nil, error: error, retry_after: retry_after)
    def ok? = error.nil?
    # The text a model reads: the JSON on success, the message on failure.
    def text = ok? ? JSON.generate(value) : error
  end

  def self.all = [ GetPortfolio, GetAccountHealth, GetQuotes, GetPriceHistory, GetJournal, GetSetupStats, GetRiskRules, EvaluateHypotheticalOrder, ProposeOrder ]

  def self.for(transport)
    case transport.to_sym
    when :mcp then all.select(&:mcp_allowed?)
    when :scheduled then all.select { |t| t.scheduled_allowed? && t.read_only? }
    else raise ArgumentError, "unknown transport #{transport}"
    end
  end

  def self.definitions(transport) = self.for(transport).map(&:definition)
  def self.find(name, transport:) = self.for(transport).find { |t| t.tool_name == name.to_s }

  # Permission check, argument validation, telemetry, timing, and error normalization in one place.
  # Never raises to the caller: Schwab and tool failures become results the agent can read and act on.
  # Every call writes a tool_calls row, including a call the transport is not allowed to make.
  def self.call(name, arguments = {}, transport:, agent_run: nil)
    arguments = arguments.to_h.deep_symbolize_keys
    record = ToolCall.new(agent_run: agent_run, transport: transport, tool_name: name.to_s, arguments: Agent.serialize(arguments))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = if (tool = find(name, transport: transport))
      invoke(tool, arguments)
    elsif all.any? { |t| t.tool_name == name.to_s }
      Result.failure("#{name} is not available on the #{transport} transport")
    else
      Result.failure("unknown tool #{name}")
    end
    record.duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    record.error = result.error
    record.save!
    # An audited tool's row says what was asked and how it ended, after the fact, linked to its telemetry.
    AuditEvent.log("agent_tool_used", actor: :agent, reason: result.error, data: { tool: tool.tool_name, transport: transport.to_s, arguments: Agent.serialize(arguments), ok: result.ok?, tool_call_id: record.id }) if tool&.audited?
    result
  end

  def self.invoke(tool, arguments)
    tool.validate!(arguments)
    Result.success(Agent.serialize(tool.new.call(**arguments)))
  rescue Schwab::RateLimited => e
    Result.failure("Schwab rate limit: try again in #{e.retry_after || 60} seconds", retry_after: e.retry_after || 60)
  rescue Schwab::NoUsableToken, Schwab::AuthError => e
    Result.failure("Schwab connection needs re-authentication: #{e.message}")
  rescue Schwab::Error => e
    Result.failure("Schwab unavailable: #{e.message}")
  rescue Agent::Tool::InvalidArguments => e
    Result.failure("bad arguments: #{e.message}")
  rescue StandardError, NotImplementedError => e # NotImplementedError is a ScriptError: the base class's own contract
    Rails.error.report(e, handled: true, context: { tool: tool.tool_name })
    Result.failure("#{tool.tool_name} failed: #{e.class.name}")
  end
  private_class_method :invoke
end
