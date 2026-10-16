# The deployment policy in the rule editor's book section, superseded like a rule and locked like one during a halt.
class DeploymentPoliciesController < ApplicationController
  before_action :require_approver

  # By id, like a rule: a form saved after another edit superseded its version is refused, not applied over it.
  def update
    policy = DeploymentPolicy.find(submitted[:id])
    successor = policy.supersede!(mode: submitted[:mode], weeks: submitted[:weeks], user: Current.user, note: submitted[:note].presence, override_reason: submitted[:override_reason])
    redirect_to risk_rules_path(anchor: "deployment"), notice: "Deployment policy is now version #{successor.version}: #{successor.summary}."
  rescue Superseding::Locked => e
    redirect_to risk_rules_path(anchor: "deployment"), alert: e.message
  rescue ActiveRecord::StaleObjectError
    redirect_to risk_rules_path(anchor: "deployment"), alert: "The policy changed since this form loaded; it is now version #{DeploymentPolicy.current.version}. Nothing was saved."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to risk_rules_path(anchor: "deployment"), alert: e.record.errors.full_messages.to_sentence
  end

  private
    def submitted = params.fetch(:deployment_policy, {})
end
