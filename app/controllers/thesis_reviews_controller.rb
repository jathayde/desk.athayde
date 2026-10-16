# A thesis review's page: the thesis, the numbers it was raised on, and whether the book has moved on since.
class ThesisReviewsController < ApplicationController
  def show
    @review = ThesisReview.find(params[:id])
    @target = Allocation::Target.active.find_by(instrument: @review.instrument)
    @latest = @target&.drifts&.order(as_of: :desc)&.first
    @chart = PriceChart.for(@review.instrument)
  end
end
