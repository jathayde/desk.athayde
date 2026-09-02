# Phase 2 step 1: the proposal state machine's columns and invariants, the halt split, the approver, audited
# rules, the watchlist, and the nightly stop suggestion. See docs/phase-2-plan.md §1 and docs/phase-2-state-table.md.
class PhaseTwoPrerequisites < ActiveRecord::Migration[8.1]
  def change
    change_table :order_proposals do |t|
      t.jsonb :collar, null: false, default: {}
      t.jsonb :sizing, null: false, default: {}
      t.timestamptz :evaluated_at
      t.timestamptz :decided_at
      t.references :decided_by, foreign_key: { to_table: :users }
      t.boolean :shadow, null: false, default: false
      t.string :broker_order_id
      t.references :parent_proposal, foreign_key: { to_table: :order_proposals }
      t.string :child_action
      t.remove :approved_at, type: :timestamptz
      t.rename :reject_reason, :rejection_reason
    end
    add_index :order_proposals, :broker_order_id, unique: true, where: "broker_order_id IS NOT NULL"
    # One live submission per instrument: two proposals cannot both be in flight, whatever two tabs do.
    add_index :order_proposals, [ :account_id, :instrument_id ], unique: true, where: "status IN ('submitting', 'submission_unknown')", name: "index_order_proposals_one_unresolved_per_instrument"

    change_table :submission_attempts do |t|
      t.string :broker_order_id
      t.timestamptz :reconciled_at
    end
    # One live attempt per proposal: a second insert while one stands is the duplicate-order bug, refused by the database.
    add_index :submission_attempts, :order_proposal_id, unique: true, where: "outcome NOT IN ('failed', 'not_placed')", name: "index_submission_attempts_one_live_per_proposal"

    change_table :risk_rules do |t|
      t.string :mode, null: false, default: "block"
      t.text :note
      t.references :changed_by, foreign_key: { to_table: :users }
    end
    remove_index :risk_rules, [ :rule_type, :setup_id ], unique: true, where: "active", name: "index_risk_rules_one_active_per_type_and_setup"
    add_index :risk_rules, [ :rule_type, :setup_id ], unique: true, where: "active", nulls_not_distinct: true, name: "index_risk_rules_one_active_per_type_and_setup"

    change_table :system_settings do |t|
      t.string :rule_halt_rule
      t.string :rule_halt_reason
      t.timestamptz :rule_halt_tripped_at
      t.timestamptz :rule_halt_resets_at
      t.timestamptz :shadow_mode_changed_at
    end

    add_column :users, :approver, :boolean, null: false, default: false

    change_table :positions do |t|
      t.decimal :suggested_stop, precision: 18, scale: 4
      t.string :suggested_stop_method
    end

    create_table :watchlist_items do |t|
      t.references :instrument, foreign_key: true
      t.string :symbol, null: false
      t.text :trigger
      t.text :thesis
      t.string :origin, null: false
      t.references :user, foreign_key: true
      t.string :status, null: false, default: "watching"
      t.timestamps
    end
    add_index :watchlist_items, [ :symbol, :status ]
  end
end
