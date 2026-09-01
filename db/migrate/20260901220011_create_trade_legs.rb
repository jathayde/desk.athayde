class CreateTradeLegs < ActiveRecord::Migration[8.1]
  def change
    create_table :trade_legs do |t|
      t.references :trade, null: false, foreign_key: true
      t.references :activity, foreign_key: true, index: false
      t.string :kind, null: false
      t.decimal :quantity, precision: 18, scale: 6
      t.decimal :price, precision: 18, scale: 4
      t.decimal :ratio, precision: 12, scale: 6
      t.decimal :cash_amount, precision: 18, scale: 4
      t.datetime :executed_at # nil on the synthetic entry leg of a bootstrapped trade
      t.string :note

      t.timestamps
    end
    add_index :trade_legs, :activity_id, unique: true, where: "activity_id IS NOT NULL"
  end
end
