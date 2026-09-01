class CreateBalances < ActiveRecord::Migration[8.1]
  def change
    create_table :balances do |t|
      t.references :account, null: false, foreign_key: true
      t.datetime :as_of, null: false
      t.decimal :equity, precision: 18, scale: 4
      t.decimal :cash_available_for_trading, precision: 18, scale: 4
      t.decimal :unsettled_cash, precision: 18, scale: 4
      t.decimal :settled_cash, precision: 18, scale: 4
      t.decimal :buying_power, precision: 18, scale: 4
      t.jsonb :raw, null: false, default: {}

      t.timestamps
    end
    add_index :balances, [ :account_id, :as_of ]
  end
end
