class Agent::Tools::GetRiskRules < Agent::Tool
  tool description: "The active guardrail rules. The guardrail engine ships in Phase 2; until then this returns no rules and available: false, " \
                    "which means unknown, not unlimited.",
       output: { rules: { type: "array", items: { type: "object" } }, available: { type: "boolean" }, phase: { type: "integer" } }

  # Phase 1 has no guardrail engine, so no rows are read: a rule row without an engine would be a lie to the agent.
  def call = { available: false, phase: 1, rules: [] }
end
