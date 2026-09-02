# The agent's notes on a trade live beside the human's post-mortem, never in it; a stop suggestion carries the
# time it was computed; one watching row per symbol is a database rule.
class AgentNotesAndSuggestionStamps < ActiveRecord::Migration[8.1]
  def change
    add_column :trades, :agent_notes, :text
    add_column :positions, :suggested_at, :timestamptz
    add_index :watchlist_items, :symbol, unique: true, where: "status = 'watching'", name: "index_watchlist_items_one_watching_per_symbol"
  end
end
