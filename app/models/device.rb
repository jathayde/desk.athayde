# A phone the shell registered for pushes: the token is the identity, re-registering refreshes the row (and,
# audited, moves it to whoever is signed in), and the row is what Push::Deliver will read once the APNs gem
# is decided.
class Device < ApplicationRecord
  belongs_to :user

  enum :platform, { ios: "ios" }
  normalizes :token, with: ->(token) { token.strip }
  validates :token, presence: true

  def self.register!(user:, platform:, token:, app_version: nil, attempt: 1)
    transaction do
      device = find_or_initialize_by(token: token)
      reason = device.new_record? ? "registered" : ("reassigned" if device.user_id != user.id)
      device.update!(user: user, platform: platform, app_version: app_version.presence, last_seen_at: Time.current)
      AuditEvent.log("device_registered", actor: :human, user: user, subject: device, reason: reason, data: { platform: device.platform, app_version: device.app_version }) if reason
      device
    end
  rescue ActiveRecord::RecordNotUnique
    raise if attempt > 1 # two launches raced on the same token; the second finds the row on its second look
    register!(user: user, platform: platform, token: token, app_version: app_version, attempt: attempt + 1)
  end
end
