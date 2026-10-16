# Phase 2.5 step 4: new cash is detected from the activities feed and deployed per the policy, at once, in weekly
# tranches, or after asking (docs/phase-2.5-plan.md §0.8, §1). An ask is a thesis review about a deposit, not an
# instrument; a deployment proposal freezes the notes it was shown.
class CashDeployment < ActiveRecord::Migration[8.1]
  def change
    create_table :cash_inflows do |t|
      t.references :account, null: false, foreign_key: true
      t.references :activity, null: false, foreign_key: true, index: { unique: true }
      t.decimal :amount, precision: 18, scale: 4, null: false
      t.timestamptz :detected_at, null: false
      t.references :deployment_policy, null: false, foreign_key: true
      t.string :status, null: false
      t.jsonb :detail, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :cash_inflows, "status IN ('pending', 'proposed', 'staged', 'asked', 'held', 'done')", name: "cash_inflows_status"
    add_check_constraint :cash_inflows, "amount > 0", name: "cash_inflows_amount_positive"

    create_table :deployment_tranches do |t|
      t.references :cash_inflow, null: false, foreign_key: true
      t.integer :week, null: false
      t.date :due_on, null: false
      t.decimal :amount, precision: 18, scale: 4, null: false
      t.string :status, null: false, default: "scheduled"
      t.jsonb :detail, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :deployment_tranches, "status IN ('scheduled', 'proposed', 'rolled', 'done')", name: "deployment_tranches_status"
    add_index :deployment_tranches, [ :cash_inflow_id, :week ], unique: true
    add_check_constraint :deployment_tranches, "amount > 0", name: "deployment_tranches_amount_positive"

    change_column_null :thesis_reviews, :instrument_id, true
    add_reference :thesis_reviews, :cash_inflow, foreign_key: true, index: { unique: true, where: "decision IS NULL", name: "index_thesis_reviews_one_open_per_inflow" }
    add_check_constraint :thesis_reviews, "reason <> 'drift' OR instrument_id IS NOT NULL", name: "thesis_reviews_drift_names_instrument"
    add_check_constraint :thesis_reviews, "reason <> 'deployment_ask' OR cash_inflow_id IS NOT NULL", name: "thesis_reviews_ask_names_inflow"
    remove_check_constraint :thesis_reviews, "decision IS NULL OR decision IN ('deploy', 'hold', 'exit')", name: "thesis_reviews_decision"
    add_check_constraint :thesis_reviews, "decision IS NULL OR decision IN ('deploy', 'stage', 'hold', 'exit')", name: "thesis_reviews_decision"

    add_column :order_proposals, :context, :jsonb, null: false, default: {}
  end
end
