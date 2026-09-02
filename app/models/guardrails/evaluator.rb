# Runs every rule over one proposal: the built-in laws, then each data rule from one query of the active rows
# (a missing row is unavailable, or a block for the rules the plan calls hard). Pure: it reads the database
# and answers; the proposal's evaluate! and the approve path write.
class Guardrails::Evaluator
  BUILT_IN = %w[ halt pending_reconciliation settled_cash position_coverage ].freeze

  def initialize(proposal, context: Guardrails::Context.new(proposal.account))
    @proposal, @context = proposal, context
  end

  def call
    active = RiskRule.active_set_for(@proposal.setup)
    results = BUILT_IN.map { |type| judge(type, nil) }
    results += RiskRule::TYPES.map { |type| active[type] ? judge(type, active[type]) : missing(type) }
    Guardrails::Report.new(results)
  end

  private
    def judge(type, rule) = Guardrails::Rule.for(type).new(rule: rule, proposal: @proposal, context: @context).call

    def missing(type)
      klass = Guardrails::Rule.for(type)
      Guardrails::Result.new(rule_type: type, outcome: klass.fatal_when_missing? ? :block : :unavailable, detail: { reason: "no #{type} rule configured" })
    end
end
