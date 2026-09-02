# The guardrail engine (docs/phase-2-plan.md §3): rules as data, evaluated in Rails against every proposal,
# never bypassed or edited through a tool. Evaluation answers; the writers (evaluate!, the approve path) act.
module Guardrails
  OUTCOMES = %i[ pass caution block unavailable skipped ].freeze

  # One rule's verdict. overridable: a caution the approver may pass with a logged reason (today, only the
  # collar). trip: a rule halt this verdict asks the writer to engage, with its reset time (nil = until cleared).
  Result = Data.define(:rule_type, :outcome, :detail, :version, :params, :overridable, :trip) do
    def initialize(rule_type:, outcome:, detail: {}, version: nil, params: {}, overridable: false, trip: nil) = super
    def pass? = outcome == :pass
    def caution? = outcome == :caution
    def block? = outcome == :block
    def unavailable? = outcome == :unavailable
    def skipped? = outcome == :skipped
  end

  # What one evaluation said, in the shape the proposal stores and the detail page reads; loaded back from
  # that shape so the stored evaluation is read by the same predicates that judged it.
  Report = Data.define(:results) do
    def self.load(hash)
      new(hash.to_h.map do |type, r|
        Result.new(rule_type: type, outcome: r["outcome"].to_sym, detail: r["detail"] || {}, version: r["version"], params: r["params"] || {}, overridable: r["overridable"] == true)
      end)
    end

    def blocked? = results.any?(&:block?)
    def warnings = results.select { |r| r.caution? || r.unavailable? }.map(&:rule_type)
    def needs_override? = results.any? { |r| r.caution? && r.overridable }
    def trips = results.filter_map(&:trip)
    def to_h = results.to_h { |r| [ r.rule_type, { "outcome" => r.outcome.to_s, "detail" => Agent.serialize(r.detail), "version" => r.version, "params" => r.params, "overridable" => r.overridable } ] }
  end

  # The one place a report changes the desk: the halts its rules asked for, engaged by the writer that owns the transaction.
  def self.engage_halts!(report, settings: SystemSettings.instance)
    report.trips.each { |trip| settings.trip_rule_halt!(rule: trip[:rule], reason: trip[:reason], resets_at: trip[:resets_at]) }
  end
end
