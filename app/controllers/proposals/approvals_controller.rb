# The deliberate confirm (Flow 2): the approver types the word, acknowledges every warning, and gives a
# reason for a collar override; the approve is the submission.
class Proposals::ApprovalsController < ApplicationController
  CONFIRMATION = "approve".freeze

  before_action :require_approver

  def create
    proposal = OrderProposal.find(params[:proposal_id])
    return redirect_to proposal_path(proposal), alert: "Type #{CONFIRMATION} to confirm." unless params[:confirmation].to_s.strip.casecmp?(CONFIRMATION)
    proposal.approve_and_submit!(user: Current.user, acknowledged: Array(params[:acknowledged]), override_reason: params[:override_reason])
    redirect_to proposal_path(proposal), notice: proposal.shadow? ? "Approved in shadow mode: place it at Schwab by hand; the sync will match it." : "Approved and submitted."
  rescue Submission::Refused, OrderProposal::IllegalTransition => e
    redirect_to proposal_path(proposal), alert: e.message
  end
end
