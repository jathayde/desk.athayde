class Position < ApplicationRecord
  belongs_to :account
  belongs_to :instrument
  belongs_to :working_stop_order, class_name: "Order", optional: true

  validates :instrument_id, uniqueness: { scope: :account_id }

  def stop_price = working_stop_order&.stop_price

  # Every live terminal sell stop on this instrument, so a scale-in covered by two stops reads as covered.
  def live_stops = @live_stops ||= account.orders.where(instrument: instrument).stops.sells.live.terminal.to_a

  def covered_quantity
    return nil unless working_stop_order
    live_stops.filter_map(&:remaining).sum
  end

  # Why this position is or is not protected. Only :protected counts; every other state is unknown or
  # insufficient risk, and the dashboard says which. Memoized: it costs a query and views ask repeatedly.
  def protection
    @protection = @live_stops = nil if @protection_for != working_stop_order_id
    @protection_for = working_stop_order_id
    @protection ||= compute_protection
  end

  def reload(...)
    @protection = @live_stops = nil
    super
  end

  def compute_protection
    return :unprotected unless working_stop_order&.working?
    return :awaiting if !working_stop_order.live?
    return :trailing_unknown if stop_price.blank? || live_stops.any? { |o| o.stop_price.blank? }
    return :oversized if covered_quantity > quantity
    return :partial if covered_quantity < quantity
    return :unpriced if last_price.blank?
    :protected
  end

  def protected? = protection == :protected
  def unprotected? = !protected?

  # Signed fraction of price between here and the stop; negative once price has gapped through it. Shown
  # whenever a stop price exists, since a partially covered stop is still the number to act on.
  def distance_to_stop
    return unless working_stop_order&.working? && stop_price.present? && last_price.present? && last_price.nonzero?
    (last_price - stop_price) / last_price
  end

  def unrealized_pnl = market_value && cost_basis ? market_value - cost_basis : nil

  # Dollars still at risk if the stops fill, each tranche at its own stop price. Unknown (nil) without a usable
  # stop, never zero for that reason, and never negative: a tranche already through its stop has nothing left to protect.
  def open_risk
    return unless protected?
    live_stops.sum { |stop| [ stop.remaining * (last_price - stop.stop_price), 0 ].max }
  end

  # The newest terminal working sell stop on this instrument, preferring live statuses over AWAITING_* so a
  # new bracket child cannot displace the stop on an existing lot. Assigned regardless of price; #protection decides.
  def assign_working_stop!
    candidates = account.orders.where(instrument: instrument).stops.sells.working.terminal.to_a
    pick = newest(candidates.select(&:live?)) || newest(candidates)
    @live_stops = nil
    update!(working_stop_order: pick)
  end

  private
    def newest(orders) = orders.max_by { |o| o.entered_at || Time.at(0) }
end
