# Accept or reject on the frozen verdict (docs/phase-2.6-plan.md §0.6).
class Hypotheses::DecisionsController < ApplicationController
  before_action :require_approver

  def create
    hypothesis = Hypothesis.find(params[:hypothesis_id])
    hypothesis.decide!(decision: params[:decision], user: Current.user, reason: params[:reason].to_s.strip)
    redirect_to research_path(anchor: "hypothesis-#{hypothesis.id}"), notice: "Hypothesis ##{hypothesis.id} #{hypothesis.status}."
  rescue ArgumentError => e
    redirect_to research_path(anchor: "hypothesis-#{params[:hypothesis_id]}"), alert: e.message
  end
end
