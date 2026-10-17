# The operator's own forecast on a waiting entry (docs/phase-2.6-plan.md §0.2): a probability and a horizon against
# the proposal's levels, made blind to the agent's unless the operator chose to look first, which the row records
# from the reveal's own audit row.
class Proposals::ForecastsController < ApplicationController
  before_action :require_approver

  def create
    proposal = OrderProposal.find(params[:proposal_id])
    proposal.with_lock do
      raise ArgumentError, "proposal #{proposal.id} is #{proposal.status_label}; a forecast is added while it waits" unless proposal.approvable?
      Forecast.record!(proposal, author: :human, user: Current.user, probability: params[:probability], horizon_days: params[:horizon_days])
    end
    redirect_to proposal_path(proposal), notice: "Forecast recorded."
  rescue ActiveRecord::RecordNotUnique
    redirect_to proposal_path(proposal), alert: "You have already forecast this one; a forecast is never changed."
  rescue ArgumentError => e
    redirect_to proposal_path(proposal), alert: e.message
  end
end
