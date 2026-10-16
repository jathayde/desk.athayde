# Lets the planner propose again on a target whose last rebalance the operator rejected.
class AllocationTargets::RejectionClearancesController < ApplicationController
  before_action :require_approver

  def create
    target = Allocation::Target.find(params[:allocation_target_id]).clear_rejection!(user: Current.user)
    redirect_to allocation_targets_path, notice: "#{target.label} may be proposed again at the next check."
  rescue ActiveRecord::StaleObjectError
    redirect_to allocation_targets_path, alert: "That target was retired in the meantime."
  end
end
