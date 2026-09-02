# The guardrail engine (docs/phase-2-plan.md §3): rules as data, evaluated in Rails against every proposal,
# never bypassed or edited through a tool.
module Guardrails
  # One rule's verdict. overridable: a warn the approver may pass with a logged reason (today, only the collar).
  Result = Data.define(:rule_type, :outcome, :detail, :version, :params, :overridable) do
    def initialize(rule_type:, outcome:, detail: {}, version: nil, params: {}, overridable: false) = super
    def pass? = outcome == :pass
    def warn? = outcome == :warn
    def fail? = outcome == :fail
    def unavailable? = outcome == :unavailable
  end

  # What one evaluation said, in the shape the proposal stores and the detail page reads.
  Report = Data.define(:results) do
    def blocked? = results.any?(&:fail?)
    def warnings = results.select { |r| r.warn? || r.unavailable? }.map(&:rule_type)
    def needs_override? = results.any? { |r| r.warn? && r.overridable }
    def to_h = results.to_h { |r| [ r.rule_type, { "outcome" => r.outcome.to_s, "detail" => Agent.serialize(r.detail), "version" => r.version, "params" => r.params, "overridable" => r.overridable } ] }
  end
end
