# The rule editor (Flow 6): one row per active rule, trade rules and book rules under their own headings, edited by superseding, with an effect preview over the
# proposals waiting today. Locked while any halt is engaged, except through the override: a typed reason, so
# a misconfigured rule that caused a false halt can be fixed without waiting for the reset.
class RiskRulesController < ApplicationController
  before_action :require_approver

  def index
    rules = RiskRule.active.includes(:setup).order(:rule_type, :setup_id)
    @trade_rules, @book_rules = rules.partition(&:scope_trade?)
    @deployment_policy = DeploymentPolicy.current
    @settings = SystemSettings.instance
  end

  def update
    rule = RiskRule.find(params[:id])
    successor = rule.supersede!(params: submitted_params(rule), mode: submitted_mode(rule), user: Current.user,
                                note: submitted[:note].presence, override_reason: submitted[:override_reason])
    redirect_to risk_rules_path, notice: "#{successor.rule_type.humanize} is now version #{successor.version}."
  rescue Superseding::Locked => e
    redirect_to risk_rules_path, alert: e.message
  rescue ActiveRecord::StaleObjectError
    redirect_to risk_rules_path, alert: "That rule changed since this form loaded. Nothing was saved."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to risk_rules_path, alert: e.record.errors.full_messages.to_sentence
  end

  # Nothing is written. The band is previewed against last night's drift rows; other book rules have nothing to re-judge.
  def preview
    rule = RiskRule.active.find(params[:id])
    return redirect_to(risk_rules_path(anchor: "book"), alert: "#{rule.rule_type.humanize} has no preview.") unless rule.previewable?
    @preview = rule.preview(params: submitted_params(rule), mode: submitted_mode(rule))
    render :band_preview if @preview.is_a?(Allocation::BandPreview)
  end

  private
    def submitted = params.fetch("rule_#{params[:id]}", {})
    def submitted_params(rule) = rule.param_keys.to_h { |key| [ key, submitted.dig(:params, key).to_s.strip ] }.compact_blank
    def submitted_mode(rule) = rule.mode_choosable? ? submitted[:mode].to_s.presence_in(RiskRule.modes.keys) : nil
end
