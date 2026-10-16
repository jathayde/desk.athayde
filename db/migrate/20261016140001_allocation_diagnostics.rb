# Phase 2.5 step 5: the Saturday diagnostics the Sunday review reads as stored rows (docs/phase-2.5-plan.md §0.9, §1):
# cash drag against the targets and the deployment policy, each holding's and diversifier's correlation with SPY,
# and the weekly fund-flow datapoint, entered by hand until a source is verified.
class AllocationDiagnostics < ActiveRecord::Migration[8.1]
  def change
    create_table :cash_drag_diagnostics do |t|
      t.date :as_of, null: false, index: { unique: true }
      t.references :deployment_policy, foreign_key: true
      t.decimal :cash_percent, precision: 9, scale: 6
      t.decimal :intended_cash_percent, precision: 9, scale: 6
      t.integer :weeks_in_cash, null: false, default: 0
      t.integer :threshold_weeks, null: false
      t.boolean :flagged, null: false, default: false
      t.jsonb :detail, null: false, default: {}
      t.timestamps
    end

    create_table :correlations do |t|
      t.references :instrument, null: false, foreign_key: true, index: false
      t.date :as_of, null: false
      t.integer :window_days, null: false
      t.decimal :value, precision: 7, scale: 6, null: false
      t.date :last_close_on, null: false # the last close in the window, which is what the value is as of
      t.timestamps
    end
    add_index :correlations, [ :instrument_id, :as_of, :window_days ], unique: true
    add_index :correlations, :as_of
    add_check_constraint :correlations, "value BETWEEN -1 AND 1", name: "correlations_value_range"

    create_table :fund_flows do |t|
      t.date :as_of, null: false, index: { unique: true }
      t.decimal :amount, precision: 18, scale: 2, null: false # billions of dollars, signed: net long-term fund flow for the week
      t.string :source, null: false
      t.timestamptz :fetched_at, null: false
      t.timestamps
    end
  end
end
