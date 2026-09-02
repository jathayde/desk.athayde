# One guardrail, keyed by rule_type, judging one proposal over a context. Subclasses implement #evaluate and
# answer with pass, caution, block, unavailable, or skipped plus the numbers; the base turns that into a Result
# carrying the rule's version. A malformed rule row is unavailable, never a crash for the whole report.
class Guardrails::Rule
  attr_reader :rule, :proposal, :context

  def self.for(rule_type) = "Guardrails::#{rule_type.to_s.camelize}".constantize
  # A rule the plan calls a hard block (docs/phase-2-plan.md §0.10) blocks when its row is missing too.
  def self.fatal_when_missing? = false

  def initialize(rule:, proposal:, context:)
    @rule, @proposal, @context = rule, proposal, context
  end

  def call
    build(*evaluate)
  rescue KeyError => e
    build(:unavailable, { reason: e.message })
  end

  def rule_type = self.class.name.demodulize.underscore
  def param(name) = BigDecimal(rule.param(name).to_s)
  def entry? = proposal.kind_entry?
  def cost = proposal.quantity.to_d * proposal.limit_price.to_d

  def pass(**detail) = [ :pass, detail ]
  def caution(overridable: false, **detail) = [ :caution, detail, overridable ]
  def block(**detail) = [ :block, detail ]
  def unavailable(reason, **detail) = [ :unavailable, detail.merge(reason: reason) ]
  def skipped = [ :skipped, { reason: "does not apply to a #{proposal.kind.humanize.downcase}" } ]

  private
    def build(outcome, detail, overridable = false, trip = nil)
      Guardrails::Result.new(rule_type: rule_type, outcome: outcome, detail: detail, version: rule&.version, params: rule&.params || {}, overridable: overridable, trip: trip)
    end
end
