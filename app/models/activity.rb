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

  scope :unjournaled, -> { where(journaled_at: nil) }
  scope :valid_for_journal, -> { where(status: Schwab::Activity::VALID) }
  scope :chronological, -> { order(:executed_at, :id) }
  scope :flows, -> { where(kind: [ :deposit, :withdrawal ]) }

  def journaled? = journaled_at.present?
end
