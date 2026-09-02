class AddReviewDeferredAtToTrades < ActiveRecord::Migration[8.1]
  def change
    add_column :trades, :review_deferred_at, :datetime # Skip means later, not never
  end
end
