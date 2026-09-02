# Push notifications to the shell's registered devices through APNs, with token-based auth from credentials.
# Every alert still goes by email; a push is the same words on the phone, sooner.
module Push
  CONNECT_TIMEOUT = 10 # seconds
  PUSH_TIMEOUT = 15

  def self.fake? = Rails.configuration.x.push.adapter == :fake
  def self.credentials = Rails.application.credentials.apns || {}
  def self.configured? = fake? || %i[ key key_id team_id bundle_id ].all? { |name| credentials[name].present? }
  def self.topic = credentials[:bundle_id].presence || "com.meticulous.athayde-desk" # the fake's stand-in

  # A connection per delivery, closed when it is done: alerts are rare, a handshake is cheap, and a cached
  # HTTP/2 connection shared across Solid Queue threads and going stale between alerts is neither.
  def self.with_connection
    return yield FakeApns.instance if fake?
    options = { auth_method: :token, cert_path: StringIO.new(credentials.fetch(:key)), key_id: credentials.fetch(:key_id), team_id: credentials.fetch(:team_id), connect_timeout: CONNECT_TIMEOUT }
    connection = credentials[:environment].to_s == "sandbox" ? Apnotic::Connection.development(options) : Apnotic::Connection.new(options)
    yield connection
  ensure
    connection&.close
  end
end
