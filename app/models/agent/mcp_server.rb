# Builds the MCP server from the registry: the gem's Tool classes are thin adapters over Agent::Tools.call.
module Agent::McpServer
  VERSION = "1.0.0"

  def self.build
    MCP::Server.new(name: "athayde-desk", version: VERSION, tools: tools, capabilities: { tools: {} },
                    instructions: "Read-only tools over the Athayde trading desk. Numbers carry as_of and stale; null risk means unknown, never zero.",
                    configuration: MCP::Configuration.new(validate_tool_call_arguments: true, validate_tool_call_results: !Rails.env.production?,
                                                          exception_reporter: ->(e, context) { Rails.error.report(e, handled: true, context: context.to_h) }))
  end

  def self.tools
    @tools ||= Agent::Tools.for(:mcp).map do |tool|
      MCP::Tool.define(name: tool.tool_name, description: tool.description, input_schema: tool.input_schema, output_schema: tool.output_schema,
                       annotations: tool.annotations) do |server_context: nil, **arguments|
        result = Agent::Tools.call(tool.tool_name, arguments, transport: :mcp)
        if result.ok?
          MCP::Tool::Response.new([ { type: "text", text: result.text } ], structured_content: result.value)
        else
          MCP::Tool::Response.new([ { type: "text", text: result.text } ], error: true, meta: { retry_after: result.retry_after }.compact.presence)
        end
      end
    end
  end
end
