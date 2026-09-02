class WatchlistItemsController < ApplicationController
  before_action :require_approver, only: :create

  def index
    @items = WatchlistItem.current
    @dropped = WatchlistItem.dropped.order(updated_at: :desc).limit(10)
  end

  def create
    item = WatchlistItem.watch!(symbol: params[:symbol], trigger: params[:trigger], thesis: params[:thesis], origin: :human, user: Current.user)
    redirect_to watchlist_items_path, notice: "Watching #{item.symbol}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to watchlist_items_path, alert: e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    redirect_to watchlist_items_path, alert: "#{params[:symbol].to_s.upcase} is already watched."
  end
end
