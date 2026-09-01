class Order < ApplicationRecord
  belongs_to :account
  belongs_to :instrument
  belongs_to :parent_order, class_name: "Order", optional: true
  belongs_to :replaces_order, class_name: "Order", optional: true
  belongs_to :order_proposal, optional: true
  has_many :child_orders, class_name: "Order", foreign_key: :parent_order_id, dependent: :nullify, inverse_of: :parent_order
  has_many :activities, dependent: :nullify

  enum :placed_via, { schwab_direct: "schwab_direct", app: "app" }

  scope :working, -> { where(status: Schwab::Order::WORKING_STATUSES) }
  scope :stops, -> { where(order_type: Schwab::Order::STOP_TYPES) }

  def working? = Schwab::Order::WORKING_STATUSES.include?(status)
  def stop? = Schwab::Order::STOP_TYPES.include?(order_type)
end
