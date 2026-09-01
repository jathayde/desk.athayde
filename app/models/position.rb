class Position < ApplicationRecord
  belongs_to :account
  belongs_to :instrument
  belongs_to :working_stop_order, class_name: "Order", optional: true

  validates :instrument_id, uniqueness: { scope: :account_id }

  scope :protected_by_stop, -> { where.not(working_stop_order_id: nil) }
  scope :unprotected, -> { where(working_stop_order_id: nil) }

  def stop_price = working_stop_order&.stop_price

  # Every live terminal sell stop on this instrument, so a scale-in covered by two stops reads as covered.
  def live_stops = account.orders.where(instrument: instrument).stops.sells.live.terminal

  def covered_quantity
    return nil unless working_stop_order
    live_stops.filter_map(&:remaining).sum
  end

  # Why this position is or is not protected. Only :protected counts; every other state is unknown or
  # insufficient risk, and the dashboard says which.
  def protection
    return :unprotected unless working_stop_order&.working?
    return :awaiting if !working_stop_order.live?
    return :trailing_unknown if stop_price.blank?
    return :oversized if covered_quantity > quantity
    return :partial if covered_quantity < quantity
    :protected
  end

  def protected? = protection == :protected
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

  # The newest terminal working sell stop on this instrument, preferring live statuses over AWAITING_* so a
  # new bracket child cannot displace the stop on an existing lot. Assigned regardless of price; #protection decides.
  def assign_working_stop!
    candidates = account.orders.where(instrument: instrument).stops.sells.working.terminal.to_a
    pick = newest(candidates.select(&:live?)) || newest(candidates)
    update!(working_stop_order: pick)
  end

  private
    def newest(orders) = orders.max_by { |o| o.entered_at || Time.at(0) }
end
