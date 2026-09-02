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

  # Entries not yet filled on instruments not yet held: they count as positions the desk has committed to.
  def pending_new_positions
    account.order_proposals.where(kind: :entry, status: %w[ validated submitting submission_unknown submitted ]).where.not(instrument_id: positions.map(&:instrument_id)).distinct.count(:instrument_id)
  end

  # What unfilled entries on this instrument have already committed, so a second entry sees the first.
  def pending_cost_for(instrument, except: nil)
    account.order_proposals.where(instrument: instrument, kind: :entry, status: %w[ validated submitting submission_unknown submitted ]).where.not(id: except&.id).sum { |p| p.quantity.to_d * p.limit_price.to_d }
  end

  # Cash the broker reports as settled, minus every buy that already claims it (docs/phase-2-plan.md §0.9).
  # The app's own resting orders are counted once, as proposals; whether the broker's figure already nets
  # working buys is unverified (verify-on-approval item 58), so its other working buys are subtracted too.
  def projected_settled_cash
    return nil if balance_stale? || balance.settled_cash.nil?
    balance.settled_cash - pending_app_buys - live_broker_buys
  end

  def pending_app_buys
    account.order_proposals.where(status: %w[ submitting submission_unknown submitted ], side: Schwab::Order::BUY).sum { |p| p.quantity.to_d * p.limit_price.to_d }
  end

  # A market buy claims an unknown sum; the position's last price is the conservative stand-in.
  def live_broker_buys
    account.orders.working.where(side: Schwab::Order::BUY, order_proposal_id: nil).includes(:instrument).sum do |o|
      o.remaining.to_d * (o.limit_price || o.stop_price || position_for(o.instrument)&.last_price || 0).to_d
    end
  end

  # Only closed trades carry realized P&L today; a scale-out at a loss on an open trade is not seen here.
  def realized_today = @realized_today ||= account.trades.closed.where(closed_at: today_range).sum(:realized_pnl)
  def prior_equity = desk.prior_snapshot&.equity
  def drawdown = desk.latest_snapshot&.drawdown

  # What the day has already committed on the buy side, resting or filled, unknown included.
  def notional_today
    account.order_proposals.where(status: %w[ submitting submission_unknown submitted filled ], side: Schwab::Order::BUY, decided_at: today_range).sum { |p| p.quantity.to_d * p.limit_price.to_d }
  end

  private
    def today_range = MarketDay.today.in_time_zone(MarketDay::ZONE).all_day
end
