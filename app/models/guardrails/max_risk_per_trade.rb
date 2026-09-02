# Rule 1: the frozen quantity's dollars at risk against today's equity and the current percent, so an equity
# drop between proposal and approval turns a pass into a block, as docs/phase-2-plan.md §0.4 requires.
class Guardrails::MaxRiskPerTrade < Guardrails::Rule
  def self.fatal_when_missing? = true

  def evaluate
    return skipped unless entry?
    return block(reason: proposal.sizing["reason"] || "not sized") if proposal.sizing["quantity"].blank?
    equity = context.fresh_equity or return block(reason: "no fresh equity to measure risk against")
    at_risk = proposal.quantity.to_d * (proposal.limit_price.to_d - proposal.stop_price.to_d)
    budget = (equity * param(:percent) / 100).round(2)
    detail = { at_risk: at_risk, budget: budget, equity: equity, frozen_budget: proposal.sizing["risk_budget"] }
    at_risk <= budget ? pass(**detail) : block(**detail)
  end
end
