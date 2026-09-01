class CreateRiskRules < ActiveRecord::Migration[8.1]
  def change
    create_table :risk_rules do |t|
      t.string :rule_type, null: false
      t.jsonb :params, null: false, default: {}
      t.boolean :active, null: false, default: true
      t.integer :version, null: false, default: 1
      t.references :setup, foreign_key: true
      t.references :superseded_by, foreign_key: { to_table: :risk_rules }

      t.timestamps
    end
    add_index :risk_rules, [ :rule_type, :setup_id ], unique: true, where: "active", name: "index_risk_rules_one_active_per_type_and_setup"
  end
end
