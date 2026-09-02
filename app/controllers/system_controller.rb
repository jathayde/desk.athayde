class SystemController < ApplicationController
  RESUME_CONFIRMATION = "resume".freeze

  before_action :require_approver, only: %i[ resume shadow_mode ] # anyone may pull the kill switch; only the approver clears it

  def show
    @status = SystemStatus.new
  end

  # Halt: a reason is required. Resume: the operator types the word.
  def halt
    reason = params[:reason].to_s.strip
    return redirect_to system_path, alert: "A reason is required to halt." if reason.blank?
    SystemSettings.instance.halt!(user: Current.user, reason: reason)
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
    settings.resume!(user: Current.user)
    redirect_to system_path, notice: "Resumed."
  end
end
