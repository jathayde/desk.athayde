# The operator chose to see the agent's forecast before adding theirs: on the record, so the forecast they add
# afterwards says so whatever the form sends (docs/phase-2.6-plan.md §0.2).
class Proposals::ForecastRevealsController < ApplicationController
  before_action :require_approver

  def create
    proposal = OrderProposal.find(params[:proposal_id])
    proposal.reveal_agent_forecast!(Current.user) unless proposal.agent_forecast_revealed_to?(Current.user)
    redirect_to proposal_path(proposal)
  end
end
