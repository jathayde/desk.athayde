# The one change a watchlist row takes.
class WatchlistItems::DropsController < ApplicationController
  before_action :require_approver

  def create
    item = WatchlistItem.watching.find(params[:watchlist_item_id])
    item.drop!(user: Current.user)
    redirect_to watchlist_items_path, notice: "Dropped #{item.symbol}."
  end
end
