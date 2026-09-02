# Rule 2a: one instrument's share of equity after this entry; no fresh equity, no answer, and no answer is a block.
class Guardrails::MaxPositionExposure < Guardrails::Rule
  def self.fatal_when_missing? = true

  def evaluate
    return skipped unless entry?
    equity = context.fresh_equity or return block(reason: "no fresh equity to measure exposure against")
    existing = context.position_for(proposal.instrument)&.market_value.to_d
    share = (existing + cost) / equity * 100
    detail = { percent: share.round(2), cap: param(:percent) }
    share <= param(:percent) ? pass(**detail) : block(**detail)
  end
end
