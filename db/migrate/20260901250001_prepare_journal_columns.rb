class PrepareJournalColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :trades, :review_reason, :string
    add_column :trades, :excluded_from_stats, :boolean, null: false, default: false
    add_column :trades, :stopped_out, :boolean, null: false, default: false
    add_column :trades, :initial_quantity, :decimal, precision: 18, scale: 6
    add_column :trades, :total_risk, :decimal, precision: 18, scale: 4
    add_column :trades, :quantity, :decimal, precision: 18, scale: 6, null: false, default: 0 # running, recomputed from legs
  end
end
