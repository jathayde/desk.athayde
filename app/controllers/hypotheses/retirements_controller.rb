class Hypotheses::RetirementsController < ApplicationController
  before_action :require_approver

  def create
    hypothesis = Hypothesis.find(params[:hypothesis_id])
    hypothesis.retire!(user: Current.user, reason: params[:reason].to_s.strip)
    redirect_to research_path(anchor: "hypothesis-#{hypothesis.id}"), notice: "Hypothesis ##{hypothesis.id} retired."
  rescue ArgumentError => e
    redirect_to research_path(anchor: "hypothesis-#{params[:hypothesis_id]}"), alert: e.message
  end
end
