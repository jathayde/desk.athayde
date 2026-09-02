class SystemController < ApplicationController
  RESUME_CONFIRMATION = "resume".freeze

  before_action :require_approver, only: :shadow_mode

  def show
    @status = SystemStatus.new
  end

  # Halt: a reason is required. Resume: the operator types the word.
  def halt
    reason = params[:reason].to_s.strip
    return redirect_to system_path, alert: "A reason is required to halt." if reason.blank?
    SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: reason, manual_halt_at: Time.current)
    AuditEvent.log("manual_halt_set", actor: :human, user: Current.user, reason: reason)
    redirect_to system_path, notice: "Halted."
  end

  def shadow_mode
    settings = SystemSettings.instance
    shadow = params.fetch(:shadow, {})
    return redirect_to system_path, alert: "A reason is required." if shadow[:reason].to_s.strip.blank?
    settings.toggle_shadow_mode!(user: Current.user, reason: shadow[:reason].strip, confirmation: shadow[:confirmation])
    redirect_to system_path, notice: settings.shadow_mode? ? "Shadow mode is on." : "Shadow mode is off: the next approve places a real order."
  rescue SystemSettings::Unconfirmed => e
    redirect_to system_path, alert: e.message
  end

  def resume
    settings = SystemSettings.instance
    return redirect_to system_path, alert: "Nothing is halted." unless settings.manual_halt?
    return redirect_to system_path, alert: "Type #{RESUME_CONFIRMATION} to confirm." unless params[:confirmation].to_s.strip.casecmp?(RESUME_CONFIRMATION)
    AuditEvent.log("manual_halt_cleared", actor: :human, user: Current.user, reason: settings.manual_halt_reason)
    settings.update!(manual_halt: false, manual_halt_reason: nil, manual_halt_at: nil)
    redirect_to system_path, notice: "Resumed."
  end
end
