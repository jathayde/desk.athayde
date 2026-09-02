class TradesController < ApplicationController
  FILTERS = {
    "open" => [ "Open", "No open trades." ],
    "closed" => [ "Closed", "No closed trades." ],
    "needs_review" => [ "Needs review", "Nothing waiting on you." ],
    "missing_post_mortem" => [ "Missing post-mortem", "Every closed trade has its post-mortem." ]
  }.freeze

  def index
    @filter = params[:filter].presence_in(FILTERS.keys) || "open"
    @trades = Trade.listing(@filter).includes(:instrument, :setup)
    @review_count = Trade.needing_review.count
  end

  def show
    @trade = Trade.find(params[:id])
    @position = @trade.open? ? @trade.account.positions.find_by(instrument: @trade.instrument) : nil
  end

  # The 30-second post-mortem: one line plus followed or improvised.
  def update
    @trade = Trade.find(params[:id])
    if params[:post_mortem].to_s.strip.blank? || params[:followed_setup].nil?
      return redirect_to trade_path(@trade), alert: "One line and a followed-or-improvised choice, both required."
    end
    @trade.update!(post_mortem: params[:post_mortem], followed_setup: params[:followed_setup] == "1")
    redirect_to trade_path(@trade), notice: "Saved."
  end
end
