class CreateAgentRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_runs do |t|
      t.string :kind, null: false
      t.string :status, null: false
      t.boolean :degraded, null: false, default: false
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :tool_turns, null: false, default: 0
      t.integer :input_tokens
      t.integer :output_tokens
      t.decimal :estimated_cost, precision: 18, scale: 4
      t.text :output_markdown
      t.text :error
      t.string :model

      t.timestamps
    end
    add_index :agent_runs, [ :kind, :created_at ]
  end
end
