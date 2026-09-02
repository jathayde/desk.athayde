# How many shares an entry may carry (docs/phase-2-plan.md §0.4): the max-risk-per-trade rule's percent of
# equity, divided by the per-share risk from the proposal's limit and stop, floored to whole shares. Frozen on
# the proposal at creation; the numbers behind the quantity are kept so the detail page can show its work.
Sizing = Data.define(:equity, :risk_percent, :risk_budget, :per_share_risk, :quantity, :reason) do
  def self.for(limit_price:, stop_price:, equity:, rule:)
    limit_price, stop_price, equity = [ limit_price, stop_price, equity ].map { |v| v && BigDecimal(v.to_s) } # never Float past this line
    return refused("no fresh equity", equity: equity) unless equity&.positive?
    return refused("no max_risk_per_trade rule", equity: equity) unless rule
    return refused("stop must be below the entry", equity: equity) unless limit_price && stop_price && stop_price < limit_price
    percent = BigDecimal(rule.param(:percent).to_s)
    return refused("max_risk_per_trade percent must be positive", equity: equity, percent: percent) unless percent.positive?
    budget = (equity * percent / 100).round(2)
    per_share = limit_price - stop_price
    quantity = (budget / per_share).floor
    return refused("risk budget of #{budget.to_s('F')} buys no whole share at #{per_share.to_s('F')} risk each", equity: equity, percent: percent, budget: budget, per_share: per_share) if quantity < 1
    new(equity: equity, risk_percent: percent, risk_budget: budget, per_share_risk: per_share, quantity: quantity, reason: nil)
  end

  def self.refused(reason, equity: nil, percent: nil, budget: nil, per_share: nil)
    new(equity: equity, risk_percent: percent, risk_budget: budget, per_share_risk: per_share, quantity: nil, reason: reason)
  end
  private_class_method :refused

  def sized? = quantity.present?
  # The jsonb shape: decimals as strings, the quantity an integer, like every other serialized number in the app.
  def to_h = Agent.serialize(super)
end
