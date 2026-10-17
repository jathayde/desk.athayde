# Phase 2.6 step 5 (docs/phase-2.6-plan.md §0.7, §0.8): what each trade paid against what was seen, per leg, and the
# R it would have made without that; the setups' gross figures beside their realized ones; and the Saturday decay
# check, one row per accepted hypothesis whenever a trade has closed since its last.
class CostsAndDecay < ActiveRecord::Migration[8.1]
  def change
    change_table :trades, bulk: true do |t|
      t.jsonb :slippage
      t.decimal :gross_r, precision: 10, scale: 4
    end
    change_table :setups, bulk: true do |t|
      t.decimal :gross_avg_r, precision: 10, scale: 4
      t.decimal :costed_avg_r, precision: 10, scale: 4 # realized, over the same trades as gross, so the difference is the cost
      t.integer :cost_sample_size
    end
    create_table :decay_checks do |t|
      t.references :hypothesis, null: false, foreign_key: true
      t.date :as_of, null: false
      t.integer :n, null: false
      t.decimal :mean_r, precision: 10, scale: 4
      t.decimal :interval_low, precision: 10, scale: 4
      t.decimal :interval_high, precision: 10, scale: 4
      t.decimal :expected_mean_r, precision: 10, scale: 4, null: false
      t.boolean :below, null: false, default: false
      t.boolean :flagged, null: false, default: false
      t.string :suggestion
      t.integer :open_count, null: false, default: 0
      t.jsonb :trade_ids, null: false, default: []
      t.timestamps
    end
    add_index :decay_checks, [ :hypothesis_id, :as_of ], unique: true
  end
end
