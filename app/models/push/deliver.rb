# One alert to every registered device: the same sentence as the email, a line of body, and the path the
# shell opens. A token Apple says is gone for good (410, Unregistered, BadDeviceToken) removes the device,
# audited, in one transaction; no answer, a transport error, or any other refusal is reported and the email
# that already went is the delivery. Nothing here retries, and nothing here raises: a push is never the
# caller's problem.
class Push::Deliver
  DEAD_TOKEN_REASONS = %w[ Unregistered BadDeviceToken ].freeze

  def self.call(**) = new(**).call

  def initialize(title:, body:, path:)
    @title, @body, @path = title, body, path
  end

  def call
    return 0 unless Push.configured?
    devices = Device.includes(:user).order(:id).to_a
    return 0 if devices.none? # no handshake for nobody
    Push.with_connection { |connection| devices.count { |device| deliver(connection, device) } }
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { push: @title }) # a bad key or a refused handshake
    0
  end

  private
    def deliver(connection, device)
      response = connection.push(notification_for(device), timeout: Push::PUSH_TIMEOUT)
      return report(device, "no answer") if response.nil?
      return true if response.ok?
      reason = response.body.try(:[], "reason")
      gone?(response, reason) ? remove(device, reason || "gone") : report(device, "#{response.status}: #{reason}")
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { device: device.id })
      false
    end

    def gone?(response, reason) = response.status == "410" || DEAD_TOKEN_REASONS.include?(reason)

    def report(device, what)
      Rails.error.report(RuntimeError.new("APNs #{what}"), handled: true, context: { device: device.id })
      false
    end

    def remove(device, reason)
      Device.transaction do
        device.destroy!
        AuditEvent.log("device_removed", actor: :system, user: device.user, reason: reason, data: { platform: device.platform })
      end
      false
    end

    def notification_for(device)
      Apnotic::Notification.new(device.token).tap do |n|
        n.topic = Push.topic
        n.alert = { title: @title, body: @body }
        n.sound = "default"
        n.custom_payload = { path: @path }
      end
    end
end
