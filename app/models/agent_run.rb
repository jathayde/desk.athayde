class AgentRun < ApplicationRecord
  has_many :tool_calls, dependent: :nullify

  enum :kind, { morning_brief: "morning_brief", eod: "eod", sunday_review: "sunday_review" }
  enum :status, { running: "running", succeeded: "succeeded", failed: "failed" }
end
