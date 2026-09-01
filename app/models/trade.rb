class Trade < ApplicationRecord
  belongs_to :account
  belongs_to :instrument
  belongs_to :setup, optional: true
  belongs_to :order_proposal, optional: true
  has_many :trade_legs, dependent: :destroy

  enum :status, { open: "open", closed: "closed" }

  normalizes :post_mortem, with: ->(text) { text.presence }

  scope :needing_review, -> { where(needs_review: true) }
  scope :missing_post_mortem, -> { closed.where(post_mortem: nil) }

  def realized_r_available? = initial_risk.present? && initial_risk.nonzero?
end
