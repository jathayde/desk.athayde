# The APNs stand-in for development and tests: renders every notification the way the wire would (so a
# payload past Apple's limit fails here, not in production), remembers it, and answers 200 unless a spec
# scripted the next answer (a status and reason, or a block that raises).
class Push::FakeApns
  include Singleton

  PAYLOAD_LIMIT = 4096 # bytes, Apple's

  Response = Data.define(:status, :body) do
    def ok? = status == "200"
  end

  attr_reader :pushed

  def initialize = reset!

  def reset!
    @pushed = []
    @answers = []
  end

  def enqueue(status: "200", reason: nil, &block) = @answers << (block || Response.new(status: status.to_s, body: reason ? { "reason" => reason } : {}))

  def push(notification, **)
    payload = notification.body
    raise ArgumentError, "APNs payload is #{payload.bytesize} bytes, over Apple's #{PAYLOAD_LIMIT}" if payload.bytesize > PAYLOAD_LIMIT
    @pushed << notification
    answer = @answers.shift
    answer.respond_to?(:call) ? answer.call : (answer || Response.new(status: "200", body: {}))
  end

  def close = nil
end
