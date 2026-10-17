# Phase 2.6 step 2 (docs/phase-2.6-plan.md §0.3): the Saturday calibration figures, one row per cut, appended each
# week so the history is kept and a page only ever reads what was stored.
class CreateCalibrationSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :calibration_snapshots do |t|
      t.date :as_of, null: false
      t.string :scope, null: false
      t.string :key, null: false
      t.string :label, null: false
      t.jsonb :figures, null: false, default: {}
      t.timestamps
    end
    add_index :calibration_snapshots, [ :as_of, :scope, :key ], unique: true
    add_check_constraint :calibration_snapshots, "scope IN ('overall', 'author', 'paired', 'setup')", name: "calibration_snapshots_scope"
  end
end
