class CreateOrderProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :order_proposals do |t|
      t.references :account, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.string :kind, null: false, default: "entry"
      t.references :target_order, foreign_key: { to_table: :orders }
      t.string :origin, null: false
      t.references :user, foreign_key: true
      t.string :status, null: false, default: "proposed"
      t.string :side
      t.decimal :quantity, precision: 18, scale: 6
      t.string :order_type
      t.decimal :limit_price, precision: 18, scale: 4
      t.decimal :stop_price, precision: 18, scale: 4 # the order's own trigger (stop entries)
      t.decimal :planned_stop, precision: 18, scale: 4 # the protective stop that becomes the bracket child
      t.decimal :target_price, precision: 18, scale: 4
      t.string :duration
      t.string :session
      t.string :tax_lot_method
      t.text :thesis
      t.references :setup, foreign_key: true
      t.jsonb :guardrail_results, null: false, default: {}
      t.jsonb :acknowledged_warnings, null: false, default: []
      t.text :override_reason
      t.text :reject_reason
      t.datetime :approved_at
      t.datetime :submitted_at
      t.datetime :expires_at

      t.timestamps
    end
    add_index :order_proposals, :status
    add_foreign_key :orders, :order_proposals
  end
end
