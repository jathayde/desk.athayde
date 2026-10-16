# Rule 2a: one instrument's share of equity after this entry, counting what unfilled entries on it have already
# committed; no fresh equity, no answer, and no answer is a block.
class Guardrails::MaxPositionExposure < Guardrails::Rule
  def self.fatal_when_missing? = true

  def evaluate
    return skipped unless opens_exposure?
    equity = context.fresh_equity or return block(reason: "no fresh equity to measure exposure against")
    existing = context.position_for(proposal.instrument)&.market_value.to_d
    committed = context.pending_cost_for(proposal.instrument, except: proposal)
    share = (existing + committed + cost) / equity * 100
    detail = { percent: share.round(2), cap: param(:percent), held: existing, committed: committed }
    share <= param(:percent) ? pass(**detail) : block(**detail)
  end
end
