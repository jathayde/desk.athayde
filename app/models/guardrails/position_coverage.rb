# Built in: a sell may not exceed what the desk holds, and must sell something. A desk that cannot short has
# no other reading of a larger number.
class Guardrails::PositionCoverage < Guardrails::Rule
  def evaluate
    return skipped if entry?
    held = context.position_for(proposal.instrument)&.quantity.to_d
    return block(reason: "no position in #{proposal.instrument.symbol} to sell") unless held.positive?
    return block(reason: "no quantity to sell") unless proposal.quantity.to_d.positive?
    detail = { selling: proposal.quantity.to_d, held: held }
    proposal.quantity.to_d <= held ? pass(**detail) : block(**detail)
  end
end
