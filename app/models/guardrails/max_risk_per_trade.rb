# Rule 1: the frozen quantity's dollars at risk against today's equity and the current percent, so an equity
# drop between proposal and approval turns a pass into a block, as docs/phase-2-plan.md §0.4 requires.
class Guardrails::MaxRiskPerTrade < Guardrails::Rule
  def self.fatal_when_missing? = true

  def evaluate
    return skipped unless requires_bracket?
    sizing = Sizing.load(proposal.sizing)
    return block(reason: sizing.reason || "not sized") unless sizing.sized?
    equity = context.fresh_equity or return block(reason: "no fresh equity to measure risk against")
    at_risk = proposal.quantity.to_d * (proposal.limit_price.to_d - proposal.stop_price.to_d)
    budget = Sizing.budget(equity: equity, percent: param(:percent))
    detail = { at_risk: at_risk, budget: budget, equity: equity, frozen_budget: sizing.risk_budget }
    at_risk <= budget ? pass(**detail) : block(**detail)
  end
end
