class CreateInstruments < ActiveRecord::Migration[8.1]
  def change
    create_table :instruments do |t|
      t.string :cusip
      t.bigint :schwab_instrument_id
      t.string :symbol, null: false
      t.jsonb :symbol_history, null: false, default: []
      t.string :asset_type
      t.boolean :leveraged, null: false, default: false
      t.string :description
      t.references :predecessor_instrument, foreign_key: { to_table: :instruments }

      t.timestamps
    end
    add_index :instruments, :cusip, unique: true, where: "cusip IS NOT NULL"
    add_index :instruments, :schwab_instrument_id, unique: true, where: "schwab_instrument_id IS NOT NULL"
    add_index :instruments, :symbol
  end
end
