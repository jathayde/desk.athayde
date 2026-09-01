class CreateMarketDays < ActiveRecord::Migration[8.1]
  def change
    create_table :market_days do |t|
      t.date :date, null: false
      t.boolean :trading, null: false
      t.datetime :session_opens_at
      t.datetime :regular_opens_at
      t.datetime :regular_closes_at
      t.datetime :session_closes_at
      t.jsonb :raw, null: false, default: {}
      t.datetime :fetched_at, null: false
      t.string :source, null: false, default: "schwab"

      t.timestamps
    end
    add_index :market_days, :date, unique: true
  end
end
