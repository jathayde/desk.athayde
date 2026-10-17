# Into the family every later verdict is held to (docs/phase-2.6-plan.md §0.6).
class Hypotheses::TestingsController < ApplicationController
  before_action :require_approver

  def create
    hypothesis = Hypothesis.find(params[:hypothesis_id])
    hypothesis.test!(user: Current.user, reason: params[:reason].to_s.strip)
    redirect_to research_path(anchor: "hypothesis-#{hypothesis.id}"), notice: "Hypothesis ##{hypothesis.id} is being tested: name it on the entries that follow its rules."
  rescue ArgumentError => e
    redirect_to research_path(anchor: "hypothesis-#{params[:hypothesis_id]}"), alert: e.message
  end
end
