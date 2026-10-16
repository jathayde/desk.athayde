# Deploy and exit on a drift review are decided here and then written as a proposal on the manual form, prefilled
# with the symbol, the thesis, and the close the review was raised on; hold closes the review with a reason. A
# deposit's answer is settled by the model. Whatever is proposed goes through every guardrail like any other.
class ThesisReviews::DecisionsController < ApplicationController
  before_action :require_approver

  def create
    review = ThesisReview.find(params[:thesis_review_id]).decide!(decision: params[:decision], reason: params[:reason], seen_as_of: params[:as_of], weeks: params[:weeks], user: Current.user)
    if review.proposal_kind
      redirect_to new_proposal_path(kind: review.proposal_kind, symbol: review.label, limit_price: review.close&.to_s("F"), thesis: review.thesis&.truncate(1500)), notice: review.decision_notice
    else
      redirect_to proposals_path, notice: review.decision_notice
    end
  rescue ArgumentError => e
    redirect_to thesis_review_path(params[:thesis_review_id]), alert: e.message
  rescue ActiveRecord::StaleObjectError
    redirect_to thesis_review_path(params[:thesis_review_id]), alert: "That review was decided or refreshed since you opened it; look again."
  end
end
