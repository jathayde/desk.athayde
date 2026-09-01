class CreatePositions < ActiveRecord::Migration[8.1]
  def change
    create_table :positions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.decimal :quantity, precision: 18, scale: 6, null: false
      t.decimal :average_price, precision: 18, scale: 4
      t.decimal :cost_basis, precision: 18, scale: 4
      t.decimal :market_value, precision: 18, scale: 4
      t.decimal :last_price, precision: 18, scale: 4
      t.references :working_stop_order, foreign_key: { to_table: :orders }
      t.datetime :synced_at, null: false
      t.jsonb :raw, null: false, default: {}

      t.timestamps
    end
    add_index :positions, [ :account_id, :instrument_id ], unique: true
  end
end
