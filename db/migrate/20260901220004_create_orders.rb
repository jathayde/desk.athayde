class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :account, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.string :broker_order_id, null: false
      t.string :status, null: false
      t.string :side
      t.decimal :quantity, precision: 18, scale: 6
      t.decimal :filled_quantity, precision: 18, scale: 6
      t.string :order_type
      t.decimal :limit_price, precision: 18, scale: 4
      t.decimal :stop_price, precision: 18, scale: 4
      t.string :duration
      t.string :session
      t.string :tax_lot_method
      t.string :placed_via, null: false, default: "schwab_direct"
      t.references :parent_order, foreign_key: { to_table: :orders }
      t.references :replaces_order, foreign_key: { to_table: :orders }
      t.bigint :order_proposal_id # foreign key added with order_proposals
      t.datetime :entered_at
      t.datetime :closed_at
      t.jsonb :raw, null: false, default: {}

      t.timestamps
    end
    add_index :orders, [ :account_id, :broker_order_id ], unique: true
    add_index :orders, :order_proposal_id
    add_index :orders, [ :account_id, :instrument_id, :status ]
  end
end
