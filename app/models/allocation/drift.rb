# One target's drift on one market day, written by the nightly check and read by the dashboard and the Sunday
# review, which never recompute it (docs/phase-2.5-plan.md §0.6). Weights, bands, and drift are fractions of equity;
# notional is the signed dollars back to target (positive buys) and quantity the whole shares that would move.
class Allocation::Drift < ApplicationRecord
  ACTIONS = %w[ none reported proposed thesis_review existing_proposal rejected_standing unavailable ].freeze

  belongs_to :target, class_name: "Allocation::Target", foreign_key: :allocation_target_id, inverse_of: :drifts
  belongs_to :order_proposal, optional: true
  belongs_to :thesis_review, optional: true

  enum :action, ACTIONS.index_by(&:itself), prefix: true, validate: true

  def side = notional.positive? ? "buy" : "sell"

  # The latest check's row for each active target: what every reader shows.
  scope :current, -> { where(as_of: unscoped.select("max(as_of)"), target: Allocation::Target.active).includes(target: :instrument).order(:id) }
end
