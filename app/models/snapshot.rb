# One row per account per market day, chain-linked so deposits and withdrawals never move the drawdown.
class Snapshot < ApplicationRecord
  CLOSE_DELAY = 20.minutes

  belongs_to :account

  scope :chronological, -> { order(:as_of) }

  # Writes (or rechains) the snapshot for one day from balances, flows, and positions. Returns nil, writing
  # nothing, when the day has no usable balance yet: a stale or intraday balance is never smeared across days.
  # Risk columns are stamped only when the row is first written; a rebuild cannot know past positions.
  def self.record(account, date, run: nil)
    day = MarketDay.find_by(date: date)
    return nil unless day&.schwab? && day.trading? && Time.current >= day.regular_closes_at + CLOSE_DELAY
    balance = balance_for(account, day) or return nil
    return nil unless balance.equity&.positive?

    prior = account.snapshots.where(as_of: ...date).order(as_of: :desc).first
    flows = net_flows(account, after: prior&.as_of, through: date, run: run)
    daily_return = prior ? (balance.equity - flows - prior.equity) / prior.equity : BigDecimal("0")
    index = prior ? prior.index_value * (1 + daily_return) : BigDecimal("1")
    high_water = [ prior&.high_water_index || BigDecimal("1"), index ].max

    snapshot = account.snapshots.find_or_initialize_by(as_of: date)
    snapshot.assign_attributes(equity: balance.equity, net_flows: flows, daily_return: daily_return, index_value: index,
                               high_water_index: high_water, drawdown: 1 - index / high_water)
    snapshot.assign_attributes(risk_now(account, balance.equity)) if snapshot.new_record?
    snapshot.save!
    snapshot
  end

  # Latest balance at or after the regular close on the day, else the day's latest, else nothing.
  def self.balance_for(account, day)
    window = day.date.in_time_zone(MarketDay::ZONE).all_day
    on_day = account.balances.where(as_of: window)
    on_day.where(as_of: day.regular_closes_at..).order(as_of: :desc).first || on_day.order(as_of: :desc).first
  end

  # Deposits positive, withdrawals negative, over every day since the prior snapshot so a flow on a missing
  # day is still neutralized. Share transfers count at their cash value when they carry one; a split has an
  # adjustment ratio and is not a flow; anything else unpriced is quarantined, never silently zero.
  def self.net_flows(account, after:, through:, run: nil)
    range = after ? (after + 1)..through : through..through
    cash = account.activities.flows.where(trade_date: range).sum do |activity|
      activity.flow_amount || (run&.quarantine(:unpriced_flows, activity.broker_activity_id); 0)
    end
    transfers = account.activities.transfer.where(trade_date: range).where.not(instrument_id: nil).includes(:trade_leg)
    shares = transfers.sum do |activity|
      next 0 if activity.trade_leg&.ratio
      next activity.net_amount if activity.net_amount&.nonzero?
      run&.quarantine(:unpriced_transfers, activity.broker_activity_id)
      0
    end
    cash + shares
  end

  def self.risk_now(account, equity)
    positions = account.positions.includes(:working_stop_order).to_a
    protected_positions = positions.select(&:protected?)
    open_risk = protected_positions.sum(&:open_risk)
    { open_risk_amount: open_risk, open_risk_ratio: open_risk / equity, unprotected_count: positions.size - protected_positions.size }
  end
end
