# Phase 2.5 step 3: drift on a leveraged or amplified instrument asks the operator instead of proposing
# (docs/phase-2.5-plan.md §0.7, §1). One open review per instrument; the drift row names the review it raised.
class CreateThesisReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :thesis_reviews do |t|
      t.references :account, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.string :reason, null: false
      t.text :thesis
      t.jsonb :context, null: false, default: {}
      t.string :decision
      t.text :decision_reason
      t.timestamptz :decided_at
      t.references :decided_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :thesis_reviews, :instrument_id, unique: true, where: "decision IS NULL", name: "index_thesis_reviews_one_open_per_instrument"
    add_check_constraint :thesis_reviews, "reason IN ('drift', 'deployment_ask')", name: "thesis_reviews_reason"
    add_check_constraint :thesis_reviews, "decision IS NULL OR decision IN ('deploy', 'hold', 'exit')", name: "thesis_reviews_decision"
    add_check_constraint :thesis_reviews, "(decision IS NULL) = (decided_at IS NULL)", name: "thesis_reviews_decided_together"
    add_check_constraint :thesis_reviews, "decision IS DISTINCT FROM 'hold' OR decision_reason IS NOT NULL", name: "thesis_reviews_hold_has_reason"

    add_reference :allocation_drifts, :thesis_review, foreign_key: true
  end
end
