class CreateSetups < ActiveRecord::Migration[8.1]
  def change
    create_table :setups do |t|
      t.string :name, null: false
      t.text :definition
      t.boolean :active, null: false, default: true
      t.decimal :win_rate, precision: 6, scale: 4
      t.decimal :avg_r, precision: 10, scale: 4
      t.decimal :expectancy, precision: 10, scale: 4
      t.integer :sample_size, null: false, default: 0
      t.datetime :stats_computed_at

      t.timestamps
    end
    add_index :setups, :name, unique: true
  end
end
