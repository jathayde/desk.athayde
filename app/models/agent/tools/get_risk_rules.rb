class Agent::Tools::GetRiskRules < Agent::Tool
  tool description: "The active rules as data: type, scope (trade rules judge one order; book rules judge the whole book and never block an order), params, mode, version, and the setup they apply to. " \
                    "Evaluate a candidate order with evaluate_hypothetical_order; rules cannot be edited through a tool.",
       output: { rules: { type: "array", items: { type: "object" } }, available: { type: "boolean" }, phase: { type: "integer" } }

  # available: false with no rows means the desk has no rules yet and the evaluator will block or mark
  # unavailable every one, never that trading is unlimited.
  def call
    { available: RiskRule.active.exists?, phase: 2, rules: RiskRule.active.includes(:setup).order(:scope, :rule_type).map { |r| { type: r.rule_type, scope: r.scope, params: r.params, mode: r.mode, version: r.version, setup: r.setup&.name } } }
  end
end
