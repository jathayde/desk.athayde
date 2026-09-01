class Order < ApplicationRecord
  belongs_to :account
  belongs_to :instrument, optional: true # container strategies have no leg
  belongs_to :parent_order, class_name: "Order", optional: true
  belongs_to :replaces_order, class_name: "Order", optional: true
  belongs_to :order_proposal, optional: true
  has_many :child_orders, class_name: "Order", foreign_key: :parent_order_id, dependent: :nullify, inverse_of: :parent_order
  has_many :replacements, class_name: "Order", foreign_key: :replaces_order_id, dependent: :nullify, inverse_of: :replaces_order
  has_many :activities, dependent: :nullify

  enum :placed_via, { schwab_direct: "schwab_direct", app: "app" }

  scope :working, -> { where(status: Schwab::Order::WORKING_STATUSES) }
  scope :stops, -> { where(order_type: Schwab::Order::STOP_TYPES) }
  scope :sells, -> { where(side: Schwab::Order::SELL) }
  scope :live, -> { where(status: Schwab::Order::LIVE_STATUSES) }
  scope :terminal, -> { where.not(id: select(:replaces_order_id).where.not(replaces_order_id: nil)) }

  def working? = Schwab::Order::WORKING_STATUSES.include?(status)
  def live? = Schwab::Order::LIVE_STATUSES.include?(status)
  def stop? = Schwab::Order::STOP_TYPES.include?(order_type)
  def container? = instrument_id.nil?

  def remaining = remaining_quantity || (quantity && quantity - (filled_quantity || 0))
end
