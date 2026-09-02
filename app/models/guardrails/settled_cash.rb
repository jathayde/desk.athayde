# Rule 4, a law rather than a parameter: a buy must be fully covered by settled cash after every buy that
# already claims it; a stale or missing balance is a block, since unavailable here cannot be acknowledged.
class Guardrails::SettledCash < Guardrails::Rule
  def evaluate
    return skipped unless proposal.buy?
    projected = context.projected_settled_cash
    return block(reason: "settled cash unavailable (balance stale or missing)") if projected.nil?
    projected >= cost ? pass(cost: cost, projected_settled_cash: projected) : block(cost: cost, projected_settled_cash: projected)
  end
end
