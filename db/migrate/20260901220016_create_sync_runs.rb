class CreateSyncRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :sync_runs do |t|
      t.string :feed, null: false
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.text :error
      t.integer :records_touched
      t.jsonb :unmapped_values, null: false, default: {}
      t.datetime :window_from
      t.datetime :window_to

      t.timestamps
    end
    add_index :sync_runs, [ :feed, :started_at ]
  end
end
