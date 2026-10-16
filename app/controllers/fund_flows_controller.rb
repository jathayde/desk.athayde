# The weekly fund-flow datapoint, entered by hand on the system page until a source is verified.
class FundFlowsController < ApplicationController
  before_action :require_approver

  def create
    flow = FundFlow.record!(as_of: submitted[:as_of], amount: submitted[:amount], source: submitted[:source], user: Current.user)
    redirect_to system_path(anchor: "allocation"), notice: "Fund flow for the week of #{flow.week_label} saved."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to system_path(anchor: "allocation"), alert: e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    redirect_to system_path(anchor: "allocation"), alert: "That week was saved at the same moment; check it and save again."
  end

  private
    def submitted = params.permit(:as_of, :amount, :source)
end
