class Agent::Tools::GetPortfolio < Agent::Tool
  include Agent::Tool::Desk

  tool description: "Open positions in the trading account with last price, unrealized P&L, the working stop and its protection state, " \
                    "distance to stop, and open risk. Unknown risk is null, never zero. Every number carries as_of and stale. " \
                    "Money and quantities are decimal strings.",
       output: { state: { type: "string" }, account: { type: "string" }, positions: { type: "array", items: { type: "object" } },
                 open_risk: { type: [ "object", "null" ] } }

  def call
    return { state: dashboard.state, account: "trading", positions: [], open_risk: nil } unless dashboard.ready?
    {
      state: :ready,
      account: "trading",
      positions: dashboard.rows.map { |row| position(row) },
      open_risk: { amount: dashboard.open_risk, ratio_of_equity: dashboard.open_risk_ratio, excluded: dashboard.excluded_by_reason,
                   note: "sums protected positions only; excluded positions carry unknown or insufficient risk" }
    }
  end

  private
    # A delisted holding carries no market numbers: whatever Schwab still echoes is a stale mark, not a price.
    def position(row)
      p = row.position
      priced = !p.delisted?
      { symbol: p.instrument.symbol, cusip: p.instrument.cusip, quantity: p.quantity, average_price: p.average_price, last_price: priced ? p.last_price : nil,
        market_value: priced ? p.market_value : nil, unrealized_pnl: priced ? p.unrealized_pnl : nil, protection: row.protection, stop_price: p.stop_price,
        covered_quantity: p.covered_quantity, distance_to_stop: priced ? p.distance_to_stop : nil, open_risk: p.open_risk,
        trade_id: row.trade&.id, needs_review: row.trade&.needs_review?, **stamp(row.as_of, row.stale) }
    end
end
