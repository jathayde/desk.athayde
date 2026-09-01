class Position < ApplicationRecord
  belongs_to :account
  belongs_to :instrument
  belongs_to :working_stop_order, class_name: "Order", optional: true

  validates :instrument_id, uniqueness: { scope: :account_id }

  scope :protected_by_stop, -> { where.not(working_stop_order_id: nil) }
  scope :unprotected, -> { where(working_stop_order_id: nil) }

  def stop_price = working_stop_order&.stop_price

  # A stop counts only while it is working and has a readable price; a trailing stop without one is unknown risk.
  def protected? = working_stop_order.present? && working_stop_order.working? && stop_price.present?
  def unprotected? = !protected?

  # Signed fraction of price between here and the stop; negative once price has gapped through it.
  def distance_to_stop
    return unless protected? && last_price.present? && last_price.nonzero?
    (last_price - stop_price) / last_price
  end

  # Dollars still at risk if the stop fills. Unknown (nil) without a usable stop, never zero for that reason,
  # and never negative: a position already through its stop has nothing left to protect.
  def open_risk
    return unless protected? && last_price.present?
    [ quantity * (last_price - stop_price), 0 ].max
  end
end
