# A thesis review's page: the thesis, the numbers it was raised on, and whether the book has moved on since; or,
# for a deposit, the cash and the three ways to place it.
class ThesisReviewsController < ApplicationController
  def show
    @review = ThesisReview.find(params[:id])
    return unless @review.reason_drift?
    @target = Allocation::Target.active.find_by(instrument: @review.instrument)
    @latest = @target&.drifts&.order(as_of: :desc)&.first
    @chart = PriceChart.for(@review.instrument)
  end
end
