# Rule 7: fat-finger protection on what the desk commits, per buy order and per day (today's resting, unknown,
# and filled buys count). Selling what is held is not a commitment and is not capped here.
class Guardrails::NotionalCap < Guardrails::Rule
  def self.fatal_when_missing? = true

  def evaluate
    return skipped unless proposal.buy?
    return block(reason: "no price to cap") if cost.zero?
    return block(cost: cost, per_order: param(:per_order)) if cost > param(:per_order)
    today = context.notional_today + cost
    detail = { cost: cost, today: today, per_order: param(:per_order), per_day: param(:per_day) }
    today <= param(:per_day) ? pass(**detail) : block(**detail)
  end
end
