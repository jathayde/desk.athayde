class Trades::ReviewsController < ApplicationController
  include ReviewFlow

  before_action :set_trade, :load_form

  def show
  end

  def update
    if @trade.review(setup: chosen_setup, planned_stop: planned_stop, thesis: params[:thesis], user: Current.user)
      redirect_to next_review_path(@trade), notice: "Reviewed #{@trade.instrument.symbol}."
    else
      flash.now[:alert] = @trade.errors.full_messages.to_sentence
      render :show, status: :unprocessable_content
    end
  end

  private
    def set_trade = @trade = Trade.find(params[:trade_id])

    def load_form
      @queue = Trade.review_queue.excluding(@trade)
      @setups = Setup.active.order(:name)
      @position = @trade.account.positions.find_by(instrument: @trade.instrument)
    end
    def chosen_setup = Setup.find_by(id: params[:setup_id]) || Setup.named(params[:new_setup])
    # Garbage is nil, never zero: a zero stop would manufacture a fake R.
    def planned_stop = BigDecimal(params[:planned_stop].to_s.strip, exception: false)
end
