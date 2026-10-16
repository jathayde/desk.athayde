# Deploy and exit are decided here and then written as a proposal on the manual form, prefilled; hold closes the
# review with a reason. The form's proposal goes through every guardrail like any other.
class ThesisReviews::DecisionsController < ApplicationController
  before_action :require_approver

  def create
    review = ThesisReview.find(params[:thesis_review_id]).decide!(decision: params[:decision], reason: params[:reason], seen_as_of: params[:as_of], weeks: params[:weeks], user: Current.user)
    symbol = review.label
    if review.reason_deployment_ask?
      redirect_to proposals_path, notice: "#{symbol}: #{CashInflow::ANSWERS.fetch(review.decision)}."
    elsif review.decision_hold?
      redirect_to proposals_path, notice: "Holding #{symbol}. The desk will not ask again while the drift stays on this side."
    else
      redirect_to new_proposal_path(kind: review.proposal_kind, symbol: symbol, thesis: review.thesis&.truncate(1500)), notice: "#{review.decision.humanize} #{symbol}: write the #{review.proposal_kind}."
    end
  rescue ArgumentError => e
    redirect_to thesis_review_path(params[:thesis_review_id]), alert: e.message
  rescue ActiveRecord::StaleObjectError
    redirect_to thesis_review_path(params[:thesis_review_id]), alert: "That review was decided or refreshed since you opened it; look again."
  end
end
