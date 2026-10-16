# Phase 2.5 step 1: book rules beside trade rules, the deployment policy, authored classes and tags, targets,
# and the nightly drift rows. See docs/phase-2.5-plan.md §0.1-0.4 and §1; later steps add their own tables.
class PhaseTwoFiveAllocation < ActiveRecord::Migration[8.1]
  def change
    add_column :risk_rules, :scope, :string, null: false, default: "trade"
    remove_index :risk_rules, [ :rule_type, :setup_id ], unique: true, where: "active", nulls_not_distinct: true, name: "index_risk_rules_one_active_per_type_and_setup"
    add_index :risk_rules, [ :scope, :rule_type, :setup_id ], unique: true, where: "active", nulls_not_distinct: true, name: "index_risk_rules_one_active_per_scope_type_and_setup"

    create_table :deployment_policies do |t|
      t.string :mode, null: false
      t.integer :weeks
      t.boolean :active, null: false, default: true
      t.integer :version, null: false, default: 1
      t.references :superseded_by, foreign_key: { to_table: :deployment_policies }
      t.references :changed_by, foreign_key: { to_table: :users }
      t.text :note
      t.timestamps
    end
    add_index :deployment_policies, :active, unique: true, where: "active", name: "index_deployment_policies_one_active"
    add_check_constraint :deployment_policies, "mode IN ('immediate', 'staged', 'ask')", name: "deployment_policies_mode"
    add_check_constraint :deployment_policies, "mode <> 'staged' OR weeks > 0", name: "deployment_policies_staged_has_weeks"

    add_column :instruments, :asset_class, :string

    create_table :instrument_tags do |t|
      t.references :instrument, null: false, foreign_key: true, index: false
      t.string :tag, null: false
      t.timestamps
    end
    add_index :instrument_tags, [ :instrument_id, :tag ], unique: true
    add_check_constraint :instrument_tags, "tag IN ('leveraged', 'amplified', 'diversifier')", name: "instrument_tags_tag"

    create_table :allocation_targets do |t|
      t.references :instrument, foreign_key: true, index: false
      t.string :asset_class
      t.decimal :target_weight, precision: 7, scale: 6, null: false # a fraction of equity, like every other ratio column
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_check_constraint :allocation_targets, "(instrument_id IS NULL) <> (asset_class IS NULL)", name: "allocation_targets_instrument_or_class"
    add_check_constraint :allocation_targets, "target_weight > 0 AND target_weight <= 1", name: "allocation_targets_weight_range"
    add_index :allocation_targets, :instrument_id, unique: true, where: "active AND instrument_id IS NOT NULL", name: "index_allocation_targets_one_active_per_instrument"
    add_index :allocation_targets, :asset_class, unique: true, where: "active AND asset_class IS NOT NULL", name: "index_allocation_targets_one_active_per_class"

    create_table :allocation_drifts do |t|
      t.references :allocation_target, null: false, foreign_key: true, index: false
      t.date :as_of, null: false
      t.decimal :weight, precision: 9, scale: 6
      t.decimal :target_weight, precision: 7, scale: 6, null: false
      t.decimal :band, precision: 9, scale: 6
      t.decimal :close, precision: 18, scale: 4
      t.decimal :drift, precision: 9, scale: 6
      t.decimal :notional, precision: 18, scale: 4
      t.integer :quantity
      t.string :action, null: false
      t.jsonb :detail, null: false, default: {}
      t.references :order_proposal, foreign_key: true
      t.timestamps
    end
    add_index :allocation_drifts, [ :allocation_target_id, :as_of ], unique: true
    add_index :allocation_drifts, :as_of
  end
end
