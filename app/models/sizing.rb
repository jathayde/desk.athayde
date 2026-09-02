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
    budget = budget(equity: equity, percent: percent)
    per_share = limit_price - stop_price
    quantity = (budget / per_share).floor
    return refused("risk budget of #{budget.to_s('F')} buys no whole share at #{per_share.to_s('F')} risk each", equity: equity, percent: percent, budget: budget, per_share: per_share) if quantity < 1
    new(equity: equity, risk_percent: percent, risk_budget: budget, per_share_risk: per_share, quantity: quantity, reason: nil)
  end

  # The one formula for the dollars a trade may risk, so the rule that re-judges an approval cannot drift from the sizing.
  def self.budget(equity:, percent:) = (equity.to_d * percent.to_d / 100).round(2)

  # The sizing a proposal gets today from the desk's fresh equity and the active rule: what creation freezes,
  # and what approval compares the frozen quantity against.
  def self.for_proposal(proposal)
    desk = Desk.new(account: proposal.account)
    self.for(limit_price: proposal.limit_price, stop_price: proposal.stop_price, equity: desk.balance_stale? ? nil : desk.equity,
             rule: RiskRule.active_for("max_risk_per_trade", setup: proposal.setup))
  end

  # The frozen jsonb back as the object, so a rule reads sized? and quantity rather than string keys.
  def self.load(hash)
    hash = hash.to_h
    new(equity: decimal(hash["equity"]), risk_percent: decimal(hash["risk_percent"]), risk_budget: decimal(hash["risk_budget"]), per_share_risk: decimal(hash["per_share_risk"]),
        quantity: hash["quantity"], reason: hash["reason"])
  end

  def self.decimal(value) = value.nil? ? nil : BigDecimal(value.to_s)
  private_class_method :decimal

  def self.refused(reason, equity: nil, percent: nil, budget: nil, per_share: nil)
    new(equity: equity, risk_percent: percent, risk_budget: budget, per_share_risk: per_share, quantity: nil, reason: reason)
  end
  private_class_method :refused

  def sized? = quantity.present?
  # The jsonb shape: decimals as strings, the quantity an integer, like every other serialized number in the app.
  def to_h = Agent.serialize(super)
end
