# One attempt to place a proposal's order; at most one may be live per proposal (database index). The
# reconcile job's bookkeeping lives in columns: when it last looked, whether it could see, when an absence
# was first believed, and which orders made a match ambiguous.
class SubmissionAttempt < ApplicationRecord
  belongs_to :order_proposal
  belongs_to :reconciled_order, class_name: "Order", optional: true

  enum :outcome, { pending: "pending", submitted: "submitted", would_have_submitted: "would_have_submitted", unknown: "unknown", not_placed: "not_placed", failed: "failed" }

  scope :live, -> { where.not(outcome: %w[ failed not_placed ]) }
  scope :unlooked_at_since, ->(time) { where(last_looked_at: ...time).or(where(last_looked_at: nil, attempted_at: ...time)) }

  def looked!(could_see:) = update!(last_looked_at: Time.current, last_look_could_see: could_see)
  def ambiguous!(orders) = update!(ambiguous_order_ids: orders.map(&:broker_order_id))
  def absent!
    update!(first_absence_at: first_absence_at || Time.current, ambiguous_order_ids: [])
  end
  def absent_since?(gap) = first_absence_at.present? && first_absence_at <= gap.ago
  def ambiguous? = ambiguous_order_ids.any?
  def error = response["error"]
end
