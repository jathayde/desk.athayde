# The one way a target leaves the active set; its drift rows stay with it.
class AllocationTargets::RetirementsController < ApplicationController
  before_action :require_approver

  def create
    target = Allocation::Target.find(params[:allocation_target_id]).retire!(user: Current.user)
    redirect_to allocation_targets_path, notice: "#{target.label} no longer has a target."
  rescue ActiveRecord::StaleObjectError
    redirect_to allocation_targets_path, alert: "That target was already retired."
  end
end
