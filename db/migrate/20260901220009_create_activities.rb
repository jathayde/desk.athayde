class CreateActivities < ActiveRecord::Migration[8.1]
  def change
    create_table :activities do |t|
      t.references :account, null: false, foreign_key: true
      t.references :instrument, foreign_key: true
      t.references :order, foreign_key: true
      t.string :broker_order_id
      t.string :broker_activity_id, null: false
      t.string :kind, null: false
      t.string :sub_type
      t.string :side
      t.decimal :quantity, precision: 18, scale: 6
      t.decimal :price, precision: 18, scale: 4
      t.decimal :commission, precision: 18, scale: 4, null: false, default: 0
      t.decimal :fees, precision: 18, scale: 4, null: false, default: 0
      t.decimal :net_amount, precision: 18, scale: 4
      t.date :trade_date
      t.date :settlement_date
      t.datetime :executed_at, null: false
      t.jsonb :raw, null: false, default: {}
      t.datetime :journaled_at

      t.timestamps
    end
    add_index :activities, [ :account_id, :broker_activity_id ], unique: true
    add_index :activities, [ :account_id, :instrument_id, :executed_at ]
    add_index :activities, :kind
    add_index :activities, :id, where: "journaled_at IS NULL", name: "index_activities_unjournaled"
  end
end
