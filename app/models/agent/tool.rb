# A read tool: a name derived from the class, a description, JSON schemas, permission metadata, and a call.
# Transport-neutral: the MCP adapter and the scheduled runtime both go through Agent::Tools.call.
class Agent::Tool
  # Raised by a tool for arguments the schema cannot catch; reported to the agent as its own mistake.
  class InvalidArguments < ArgumentError; end

  class << self
    attr_reader :description, :input_schema, :output_schema

    # Every output key is required unless listed in output_optional; a half-declared schema is worse than none.
    # audited: every call is an audit_events row as well as a tool_calls row; required for any tool that writes.
    def tool(description:, output:, input: {}, required: [], output_optional: [], read_only: true, mcp: true, scheduled: true, audited: !read_only)
      @description = description
      @input_schema = { type: "object", properties: input, required: required.map(&:to_s), additionalProperties: false }
      @output_schema = { type: "object", properties: output, required: (output.keys - output_optional).map(&:to_s), additionalProperties: false }
      @read_only, @mcp_allowed, @scheduled_allowed, @audited = read_only, mcp, scheduled, audited
      raise ArgumentError, "#{tool_name}: an unattended tool must be read-only" if scheduled && !read_only
      raise ArgumentError, "#{tool_name}: a tool that writes must be audited" if !read_only && !audited
    end

    def tool_name = @tool_name ||= name.to_s.demodulize.underscore.presence || "anonymous"
    def read_only? = @read_only
    def audited? = @audited
    def mcp_allowed? = @mcp_allowed
    def scheduled_allowed? = @scheduled_allowed

    def annotations = { read_only_hint: read_only?, destructive_hint: !read_only?, idempotent_hint: read_only?, open_world_hint: false }

    # The shape the Anthropic Messages API and the MCP gem both consume.
    def definition = { name: tool_name, description: description, input_schema: input_schema }

    # One gate for both transports, so the scheduled runtime gets the same checks the MCP gem applies.
    def validate!(arguments)
      validator.validate_arguments(arguments)
    rescue MCP::Tool::InputSchema::ValidationError => e
      raise InvalidArguments, e.message
    end

    private
      def validator = @validator ||= MCP::Tool::InputSchema.new(input_schema)
  end

  def call(**) = raise(NotImplementedError, "#{self.class.tool_name} does not implement #call")
end
