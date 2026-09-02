# The one change a watchlist row takes.
class WatchlistItems::DropsController < ApplicationController
  before_action :require_approver

  def create
    item = WatchlistItem.watching.find(params[:watchlist_item_id])
    item.drop!
    AuditEvent.log("watchlist_changed", actor: :human, user: Current.user, subject: item, reason: "dropped", data: { symbol: item.symbol })
    redirect_to watchlist_items_path, notice: "Dropped #{item.symbol}."
  end
end
