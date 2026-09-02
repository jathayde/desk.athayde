# The rule editor (Flow 6): one row per active rule, edited by superseding, with an effect preview over the
# proposals waiting today. Locked while any halt is engaged, except through the override: a typed reason, so
# a misconfigured rule that caused a false halt can be fixed without waiting for the reset.
class RiskRulesController < ApplicationController
  before_action :require_approver

  def index
    @rules = RiskRule.active.includes(:setup).order(:rule_type, :setup_id)
    @settings = SystemSettings.instance
  end

  def update
    rule = RiskRule.active.find(params[:id])
    successor = rule.supersede!(params: submitted_params(rule), mode: submitted_mode(rule), user: Current.user,
                                note: submitted[:note].presence, override_reason: submitted[:override_reason])
    redirect_to risk_rules_path, notice: "#{successor.rule_type.humanize} is now version #{successor.version}."
  rescue RiskRule::Locked => e
    redirect_to risk_rules_path, alert: "Rules are locked while #{e.message}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to risk_rules_path, alert: e.record.errors.full_messages.to_sentence
  end

  # Nothing is written.
  def preview
    rule = RiskRule.active.find(params[:id])
    @preview = RulePreview.new(rule, params: submitted_params(rule), mode: submitted_mode(rule))
  end

  private
    def submitted = params.fetch("rule_#{params[:id]}", {})
    def submitted_params(rule) = rule.param_keys.to_h { |key| [ key, submitted.dig(:params, key).to_s.strip ] }.compact_blank
    def submitted_mode(rule) = rule.mode_choosable? ? submitted[:mode].to_s.presence_in(RiskRule.modes.keys) : nil
end
