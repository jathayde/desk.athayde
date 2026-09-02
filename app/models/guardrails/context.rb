# Everything the rules read about the desk, computed once per evaluation from the database for one account:
# equity and its freshness, cash and what already claims it, positions, today's realized P&L, the drawdown,
# and the halts.
class Guardrails::Context
  attr_reader :account, :desk, :settings

  def initialize(account)
    @account = account
    @desk = Desk.new(account: account)
    @settings = SystemSettings.instance
  end

  def balance = desk.balance
  def equity = balance&.equity
  def balance_stale? = balance.nil? || desk.balance_stale?
  def fresh_equity = balance_stale? || equity.to_d <= 0 ? nil : equity
  def positions = @positions ||= account.positions.includes(:instrument, :working_stop_order).to_a
  def position_for(instrument) = positions.find { |p| p.instrument_id == instrument.id }
  def open_trade_for(instrument) = account.trades.open.find_by(instrument: instrument)

  # Entries not yet filled on instruments not yet held: they count as positions the desk has committed to. The
  # proposal being judged is left out, so its own validated row is not counted twice at approval.
  def pending_new_positions(except: nil)
    scope = account.order_proposals.committed.where(kind: :entry).where.not(instrument_id: positions.map(&:instrument_id))
    scope = scope.where.not(id: except.id) if except&.persisted?
    scope.distinct.count(:instrument_id)
  end

  # What unfilled entries on this instrument have already committed, so a second entry sees the first.
  def pending_cost_for(instrument, except: nil)
    account.order_proposals.committed.where(instrument: instrument, kind: :entry).where.not(id: except&.id).sum(&:cost)
  end

  # Cash the broker reports as settled, minus every buy that already claims it (docs/phase-2-plan.md §0.9).
  # The app's own resting orders are counted once, as proposals; whether the broker's figure already nets
  # working buys is unverified (verify-on-approval item 58), so its other working buys are subtracted too.
  def projected_settled_cash
    return nil if balance_stale? || balance.settled_cash.nil?
    balance.settled_cash - pending_app_buys - live_broker_buys
  end

  def pending_app_buys
    account.order_proposals.at_broker.buy.sum(&:cost)
  end

  # A market buy claims an unknown sum; the position's last price is the conservative stand-in.
  def live_broker_buys
    account.orders.working.where(side: Schwab::Order::BUY, order_proposal_id: nil).includes(:instrument).sum do |o|
      o.remaining.to_d * (o.limit_price || o.stop_price || position_for(o.instrument)&.last_price || 0).to_d
    end
  end

  # Today's realized P&L: the trades that closed today, plus every scale-out on a still-open trade, priced
  # against that trade's average entry, so a loss taken in parts is seen before the trade is done.
  def realized_today
    @realized_today ||= account.trades.closed.where(closed_at: today_range).sum(:realized_pnl) +
      account.trades.open.joins(:trade_legs).where(trade_legs: { kind: "exit", executed_at: today_range }).where.not(trade_legs: { cash_amount: nil }).where.not(avg_entry: nil)
             .sum("trade_legs.cash_amount - trade_legs.quantity * trades.avg_entry")
  end
  def prior_equity = desk.prior_snapshot&.equity
  def drawdown = desk.latest_snapshot&.drawdown

  # What the day has already committed on the buy side, resting or filled, unknown included.
  def notional_today
    account.order_proposals.where(status: OrderProposal::AT_BROKER + %w[ filled ]).buy.where(decided_at: today_range).sum(&:cost)
  end

  private
    def today_range = MarketDay.today.in_time_zone(MarketDay::ZONE).all_day
end
