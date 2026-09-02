class Trades::DeferralsController < ApplicationController
  include ReviewFlow

  def create
    trade = Trade.find(params[:trade_id])
    trade.defer_review!
    redirect_to next_review_path(trade)
  end
end
