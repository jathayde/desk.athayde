# A scripted stand-in for the Messages API. Specs and development enqueue canned responses; unscripted,
# it writes a short brief without touching a tool, so a seeded desk can send real-looking email. Every
# request is run through the SDK's own request serializer first, so a bad shape fails here, not in production.
class Agent::FakeAnthropic
  include Singleton

  Messages = Struct.new(:owner) do
    def create(params) = owner.create(params)
  end

  attr_reader :requests

  def initialize = reset!

  def reset!
    @queue = []
    @requests = []
  end

  def messages = Messages.new(self)

  # Enqueue a response hash (content blocks and stop_reason) or a block that raises. A scripted tool_use
  # under tool_choice none is a scripting mistake unless the response says ignoring_tool_choice: true.
  def enqueue(response = nil, &block) = @queue << (block || response)

  def create(params)
    body, = Anthropic::Models::MessageCreateParams.dump_request(params)
    JSON.generate(body) # what the wire would carry; raises on anything the SDK cannot serialize
    @requests << params.deep_dup # the caller keeps mutating its messages array
    scripted = @queue.shift
    return scripted.call(params) if scripted.respond_to?(:call)
    scripted ||= { content: [ { type: :text, text: "Fake brief: nothing to report. Every number above came from the desk." } ], stop_reason: :end_turn }
    if params.dig(:tool_choice, :type) == :none && scripted[:stop_reason] == :tool_use && !scripted[:ignoring_tool_choice]
      raise ArgumentError, "scripted a tool_use under tool_choice none; pass ignoring_tool_choice: true to mean it"
    end
    message(scripted)
  end

  private
    def message(response)
      Anthropic::Models::Message.new(
        id: "msg_#{SecureRandom.hex(4)}", type: :message, role: :assistant, model: Agent::MODEL, stop_sequence: nil, stop_details: nil, container: nil,
        stop_reason: response.fetch(:stop_reason, :end_turn), content: response.fetch(:content),
        usage: { input_tokens: 1200, output_tokens: 300, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 }.merge(response.fetch(:usage, {}))
      )
    end
end
