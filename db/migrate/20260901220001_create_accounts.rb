class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string :schwab_hash, null: false
      t.string :account_type # taxable/ira, set by the operator; Schwab only says CASH or MARGIN
      t.boolean :trading_enabled, null: false, default: false
      t.string :nickname
      t.datetime :last_synced_at
      t.jsonb :raw, null: false, default: {}

      t.timestamps
    end
    add_index :accounts, :schwab_hash, unique: true
  end
end
