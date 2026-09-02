# The lots a sell would consume are frozen on the proposal like its sizing and collar, so the detail page is
# the record of the decision, not today's journal.
class FreezeLotsOnProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :order_proposals, :lots, :jsonb, null: false, default: []
  end
end
