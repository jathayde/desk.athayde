# What the proposals waiting today would say under a candidate version of a rule, next to what they said when
# judged. Reads; writes nothing. Only the proposals this rule governs are shown: the setup's own row wins over
# the global one, exactly as the evaluator resolves them.
class RulePreview
  Row = Data.define(:proposal, :before, :after)
  attr_reader :rule, :candidate

  def initialize(rule, params:, mode: nil)
    @rule = rule
    @candidate = RiskRule.new(rule_type: rule.rule_type, setup: rule.setup, params: params, mode: mode.presence || rule.mode, version: rule.version + 1)
  end

  def rows
    @rows ||= proposals.map do |proposal|
      Row.new(proposal: proposal, before: proposal.guardrail_results.dig(rule.rule_type, "outcome"),
              after: Guardrails::Rule.for(rule.rule_type).new(rule: candidate, proposal: proposal, context: contexts[proposal.account]).call)
    end
  end

  private
    def proposals = OrderProposal.validated.includes(:instrument, :setup, :account).order(:id).select { |proposal| rule.applies_to?(proposal) }
    def contexts = @contexts ||= Hash.new { |cache, account| cache[account] = Guardrails::Context.new(account) }
end
