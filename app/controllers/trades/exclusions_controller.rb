class Trades::ExclusionsController < ApplicationController
  include ReviewFlow

  def create
    trade = Trade.find(params[:trade_id])
    trade.exclude!(user: Current.user)
    redirect_to next_review_path(trade), notice: "#{trade.instrument.symbol} marked not a setup trade."
  end
end
