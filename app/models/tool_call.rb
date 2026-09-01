class ToolCall < ApplicationRecord
  belongs_to :agent_run, optional: true

  enum :transport, { mcp: "mcp", scheduled: "scheduled" }
end
