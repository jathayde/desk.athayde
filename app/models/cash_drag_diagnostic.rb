# How long the book has sat in more cash than its targets leave uninvested (PRD §5.12.4): each recent week's latest
# balance up to the day measured, cash as settled plus unsettled over equity, against one minus the active targets'
# weights plus the cash committed to staged or held deposits, counted back from the latest week that has a balance
# while the excess stays above the rebalance band; the
# week the count started and why it stopped are kept. Informational, never an action.
class CashDragDiagnostic < ApplicationRecord
  WEEKS_BACK = 12

  belongs_to :deployment_policy, optional: true

  def self.record!(account, as_of: MarketDay.today)
    threshold = RiskRule.active_for("cash_drag_weeks")&.then { |rule| rule.param(:weeks).to_i } or return nil
    band = RiskRule.rebalance_band or return nil # unmeasurable without a band, as the drift check is
    committed = committed_cash(account)
    equity = account.current_balance&.equity
    intended = ([ 1 - Allocation::Target.active.sum(:target_weight), 0 ].max + (equity&.positive? ? committed / equity : 0)).clamp(0, 1)
    weekly = weekly_cash(account, as_of, [ WEEKS_BACK, threshold + 1 ].max)
    started = weekly.index { !it.nil? }
    counted = started ? weekly.drop(started) : []
    weeks = counted.take_while { |cash| cash && cash - intended > band }.size
    ended = counted[weeks].nil? && weeks < counted.size ? "no balance" : weeks < counted.size ? "inside the band" : "out of history"
    transaction do
      row = find_or_initialize_by(as_of: as_of)
      row.update!(deployment_policy: DeploymentPolicy.current, cash_percent: counted.first&.round(6), intended_cash_percent: intended.round(6), weeks_in_cash: weeks,
                  threshold_weeks: threshold, flagged: weeks >= threshold,
                  detail: { "weekly_cash" => weekly.map { it&.round(4)&.to_s }, "weeks_back_to_start" => started, "ended" => (ended if started),
                            "committed_cash" => (committed.to_s if committed.positive?) }.compact)
      AuditEvent.log("cash_drag_checked", actor: :system, subject: row, data: { cash: row.cash_percent&.to_s, intended: row.intended_cash_percent.to_s, weeks: weeks, flagged: row.flagged })
      row
    end
  end

  # Cash the operator meant to keep for now: tranches still scheduled and deposits held as cash. It counts as
  # intended, so a staging on schedule or a deliberate hold is not flagged as drag (PRD §5.12.4: divergence from policy).
  def self.committed_cash(account)
    DeploymentTranche.scheduled.where(cash_inflow: account.cash_inflows).sum(:amount) + account.cash_inflows.status_held.sum(:amount)
  end
  private_class_method :committed_cash

  # Each week's latest balance, most recent first and never past the day measured; nil for a week with none usable.
  def self.weekly_cash(account, as_of, weeks)
    (0...weeks).map do |back|
      week = (as_of - back.weeks).in_time_zone(MarketDay::ZONE).all_week
      week = week.first..as_of.in_time_zone(MarketDay::ZONE).end_of_day if back.zero?
      balance = account.balances.where(as_of: week).order(as_of: :desc).first
      next nil unless balance&.equity&.positive? && balance.settled_cash
      (balance.settled_cash + balance.unsettled_cash.to_d) / balance.equity
    end
  end
  private_class_method :weekly_cash
end
