# Writing a hypothesis or a variant (docs/phase-2.6-plan.md §0.5): the approver's, before the evidence.
class HypothesesController < ApplicationController
  before_action :require_approver

  def create
    hypothesis = Hypothesis.write!(params.expect(hypothesis: %i[ statement setup_id rules min_sample holdout_from expected_mean_r parent_id ]), user: Current.user)
    redirect_to research_path(anchor: "hypothesis-#{hypothesis.id}"), notice: "Hypothesis ##{hypothesis.id} written. Move it to testing when you mean to collect evidence for it."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to research_path(anchor: "new-hypothesis"), alert: e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::InvalidForeignKey
    redirect_to research_path(anchor: "new-hypothesis"), alert: "That setup or parent hypothesis does not exist."
  end
end
