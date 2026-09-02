# The shell registers its push token here after sign-in, by submitting the registration form the web view
# renders for it (the form carries the CSRF token; nothing is exempted); the same token re-registered
# refreshes the row.
class Native::DevicesController < ApplicationController
  rate_limit to: 30, within: 1.minute, with: -> { head :too_many_requests }

  def create
    device = Device.register!(user: Current.user, platform: params[:platform], token: params[:token], app_version: params[:app_version])
    render json: { device_id: device.id, platform: device.platform }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_content
  rescue ArgumentError => e # an unknown platform
    render json: { error: e.message }, status: :unprocessable_content
  end
end
