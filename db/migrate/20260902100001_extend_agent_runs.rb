# The runtime needs to say which market day a run served, why it stopped, whether the email left, what
# the cache did to the bill, why it was degraded, and what the model saw (for Phase 2 to audit a suggestion).
class ExtendAgentRuns < ActiveRecord::Migration[8.1]
  def change
    change_table :agent_runs do |t|
      t.date :market_date
      t.string :stop_reason
      t.timestamptz :emailed_at
      t.integer :cache_creation_input_tokens
      t.integer :cache_read_input_tokens
      t.integer :tool_calls_count, null: false, default: 0
      t.jsonb :degraded_reasons, null: false, default: []
      t.jsonb :transcript, null: false, default: []
    end
    # One run per kind and market day unless it failed; a failure may be retried.
    add_index :agent_runs, [ :kind, :market_date ], unique: true, where: "status <> 'failed'", name: "index_agent_runs_one_per_kind_and_day"
    add_index :agent_runs, :started_at
  end
end
