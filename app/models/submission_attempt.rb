# One attempt to place a proposal's order; at most one may be live per proposal (database index).
class SubmissionAttempt < ApplicationRecord
  belongs_to :order_proposal
  belongs_to :reconciled_order, class_name: "Order", optional: true

  enum :outcome, { pending: "pending", submitted: "submitted", would_have_submitted: "would_have_submitted", unknown: "unknown", not_placed: "not_placed", failed: "failed" }

  scope :live, -> { where.not(outcome: %w[ failed not_placed ]) }
end
