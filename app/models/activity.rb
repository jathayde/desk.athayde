# One row per Schwab activity: fills, dividends, fees, cash movements, corporate actions.
class Activity < ApplicationRecord
  belongs_to :account
  belongs_to :instrument, optional: true
  belongs_to :order, optional: true
  has_one :trade_leg, dependent: :restrict_with_exception

  enum :kind, {
    fill: "fill", sweep: "sweep", dividend: "dividend", interest: "interest", fee: "fee", deposit: "deposit",
    withdrawal: "withdrawal", transfer: "transfer", corporate_action: "corporate_action", other: "other"
  }

  # Every column the sync derives from one mapped activity, in one place, so the specs' helpers write rows
  # exactly as the sync does.
  def assign_from(mapped)
    assign_attributes(broker_activity_id: mapped.activity_id, broker_order_id: mapped.order_id, kind: mapped.kind, status: mapped.status, sub_type: mapped.type,
                      side: mapped.side, quantity: mapped.quantity, price: mapped.price, commission: mapped.commission, fees: mapped.fees, net_amount: mapped.net_amount,
                      trade_date: mapped.trade_date, settlement_date: mapped.settlement_date, executed_at: mapped.executed_at, raw: mapped.raw)
    self
  end

  scope :unjournaled, -> { where(journaled_at: nil) }
  scope :valid_for_journal, -> { where(status: Schwab::Activity::VALID) }
  scope :chronological, -> { order(:executed_at, :id) }
  scope :flows, -> { where(kind: [ :deposit, :withdrawal ]) }

  def journaled? = journaled_at.present?
  def buy? = side == Schwab::Order::BUY
  def cash_flow? = deposit? || withdrawal? || (transfer? && instrument_id.present?)

  # Deposits positive, withdrawals negative, whatever sign Schwab used; nil when the broker sent no amount,
  # so the caller quarantines it rather than counting zero.
  def flow_amount
    return nil unless (deposit? || withdrawal?) && net_amount
    deposit? ? net_amount.abs : -net_amount.abs
  end

  # Shares delivered in are positive, delivered out negative, read from the security item itself
  # because the cash amount on a share delivery is zero.
  def delivered_quantity
    return nil unless instrument_id && quantity
    Schwab::Activity.from(raw).securities.first&.amount&.negative? ? -quantity : quantity
  end

  # A re-synced activity whose economics changed after journaling drops its leg so the trade is rebuilt.
  def unjournal!
    transaction do
      trade = trade_leg&.trade
      trade_leg&.destroy!
      update!(journaled_at: nil)
      trade&.recompute!
    end
  end
end
