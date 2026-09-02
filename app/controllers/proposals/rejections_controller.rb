class Proposals::RejectionsController < ApplicationController
  before_action :require_approver

  def create
    proposal = OrderProposal.find(params[:proposal_id])
    proposal.reject!(user: Current.user, reason: params[:reason].to_s.strip)
    redirect_to proposals_path, notice: "Rejected #{proposal.instrument.symbol}."
  rescue ArgumentError, OrderProposal::IllegalTransition => e
    redirect_to proposal_path(proposal), alert: e.message
  end
end
