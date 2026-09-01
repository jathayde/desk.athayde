class CreateSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :snapshots do |t|
      t.references :account, null: false, foreign_key: true
      t.date :as_of, null: false
      t.decimal :equity, precision: 18, scale: 4, null: false
      t.decimal :net_flows, precision: 18, scale: 4, null: false, default: 0
      t.decimal :daily_return, precision: 12, scale: 8
      t.decimal :index_value, precision: 18, scale: 10, null: false, default: 1
      t.decimal :high_water_index, precision: 18, scale: 10, null: false, default: 1
      t.decimal :drawdown, precision: 10, scale: 6, null: false, default: 0 # fraction: 1 - index / high water
      t.decimal :open_risk_amount, precision: 18, scale: 4
      t.decimal :open_risk_ratio, precision: 10, scale: 6 # fraction of equity
      t.integer :unprotected_count, null: false, default: 0

      t.timestamps
    end
    add_index :snapshots, [ :account_id, :as_of ], unique: true
  end
end
