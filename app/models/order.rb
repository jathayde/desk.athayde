class Order < ApplicationRecord
  # SCHWAB_SHAPE_UNVERIFIED: see docs/schwab-api-contract.md for the status and type vocabularies.
  WORKING_STATUSES = %w[ WORKING ACCEPTED QUEUED PENDING_ACTIVATION AWAITING_PARENT_ORDER AWAITING_STOP_CONDITION
                         AWAITING_CONDITION NEW AWAITING_RELEASE_TIME ].freeze
  STOP_TYPES = %w[ STOP STOP_LIMIT TRAILING_STOP TRAILING_STOP_LIMIT ].freeze

  belongs_to :account
  belongs_to :instrument
  belongs_to :parent_order, class_name: "Order", optional: true
  belongs_to :replaces_order, class_name: "Order", optional: true
  belongs_to :order_proposal, optional: true
  has_many :child_orders, class_name: "Order", foreign_key: :parent_order_id, dependent: :nullify, inverse_of: :parent_order
  has_many :activities, dependent: :nullify

  enum :placed_via, { schwab_direct: "schwab_direct", app: "app" }

  scope :working, -> { where(status: WORKING_STATUSES) }
  scope :stops, -> { where(order_type: STOP_TYPES) }

  def working? = WORKING_STATUSES.include?(status)
  def stop? = STOP_TYPES.include?(order_type)
end
