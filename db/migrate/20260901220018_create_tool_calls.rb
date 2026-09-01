class CreateToolCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :tool_calls do |t|
      t.references :agent_run, foreign_key: true
      t.string :transport, null: false
      t.string :tool_name, null: false
      t.jsonb :arguments, null: false, default: {}
      t.integer :duration_ms
      t.text :error

      t.timestamps
    end
    add_index :tool_calls, [ :tool_name, :created_at ]
  end
end
