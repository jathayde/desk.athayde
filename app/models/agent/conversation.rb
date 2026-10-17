# One Messages API conversation over the read-only tool registry, bounded four ways: turns, tool calls,
# input tokens, and wall clock. Every stop reason is handled deliberately and the row records how it ended.
# The email is the job's business: a run that produced text can be delivered whatever else happened.
class Agent::Conversation
  MAX_TURNS = 12 # one Messages API round trip is a turn; parallel tool_use blocks in one response are one turn
  MAX_TOOL_CALLS = 20
  MAX_INPUT_TOKENS = 400_000 # cumulative across turns, cache reads included: a spend bound, not a context bound
  MAX_OUTPUT_TOKENS = 8192 # thinking bills as output and counts here, so small values hit the ceiling before any tool_use
  DEADLINE = 10.minutes
  TOOL_RESULT_LIMIT = 24.kilobytes
  BUDGET_EXHAUSTED = "tool budget exhausted; write the brief from what you have"
  # The skeptic writes 150 words about one proposal, once per entry: a brief's budget would be a brief's bill each time.
  SKEPTIC = { turns: 6, tool_calls: 8, input_tokens: 120_000 }.freeze
  SKEPTIC_WITHOUT = %w[ evaluate_hypothetical_order ].freeze # it answers in share counts, which the skeptic never states

  Ended = Class.new(StandardError)

  def initialize(agent_run, context: Agent::Context.new(kind: agent_run.kind, date: agent_run.market_date, proposal: agent_run.order_proposal), client: Agent.client)
    @run, @context, @client = agent_run, context, client
    @limits = agent_run.skeptic? ? SKEPTIC : { turns: MAX_TURNS, tool_calls: MAX_TOOL_CALLS, input_tokens: MAX_INPUT_TOKENS }
    @messages = []
    @degraded_reasons = context.degraded_reasons.dup
    @turns = @tool_calls = 0
    @usage = Hash.new(0)
    @texts = [] # one entry per turn, so a dropped response drops only its own words
    @max_tokens = MAX_OUTPUT_TOKENS
    @capped_by = nil
  end

  attr_reader :run

  def perform
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run.update!(model: Agent::MODEL, started_at: run.started_at || Time.current)
    @messages << { role: :user, content: @context.user_prompt }
    converse
    finish(@capped_by ? :capped : :succeeded, error: @capped_by && "budget spent: #{@capped_by}")
  rescue Ended => e
    finish(:failed, error: e.message)
  rescue Anthropic::Errors::Error => e # API, transport, timeout, and request-shape errors are all deliverable failures
    finish(:failed, error: "Anthropic #{e.class.name.demodulize}: #{e.message.to_s.truncate(300)}")
  rescue StandardError => e
    finish(:failed, error: "#{e.class}: #{e.message.truncate(300)}")
    raise
  end

  private
    def converse
      loop do
        @capped_by ||= budget_spent
        forced = @capped_by.present?
        response = call(tool_choice: forced ? { type: :none } : { type: :auto })
        @messages << { role: :assistant, content: response.content.map { |block| replay(block) } }
        @texts << response.content.select { |b| b.type == :text }.map(&:text).join("\n")
        @stop = response.stop_reason
        case @stop
        when :end_turn, :stop_sequence
          raise Ended, "the model ended without writing anything" if text.blank?
          return
        when :tool_use
          @messages << { role: :user, content: answer(response.content.select { |b| b.type == :tool_use }, forced: forced) }
        when :max_tokens
          return @capped_by ||= "output tokens" unless retry_larger? # once, dropping the cut response
        when :refusal, :pause_turn, :model_context_window_exceeded
          raise Ended, "the model stopped with #{@stop}#{": #{text.truncate(200)}" if text.present?}"
        else
          raise Ended, "unexpected stop reason #{@stop.inspect}"
        end
      end
    end

    def call(tool_choice:)
      raise Ended, "deadline of #{DEADLINE.inspect} passed before turn #{@turns + 1}" if elapsed > DEADLINE
      raise Ended, "#{@limits[:turns]} turns passed without a final answer" if @turns >= @limits[:turns]
      @turns += 1
      response = @client.messages.create(
        model: Agent::MODEL, max_tokens: @max_tokens, system_: @context.system_prompt, messages: @messages,
        tools: tools, tool_choice: tool_choice, cache_control: { type: :ephemeral },
        request_options: { timeout: Agent::REQUEST_TIMEOUT } # the client-level timeout is ignored by the SDK when this is absent
      )
      %i[ input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens ].each { |field| @usage[field] += response.usage.public_send(field).to_i }
      response
    end

    def tools = @tools ||= Agent::Tools.definitions(:scheduled).reject { run.skeptic? && SKEPTIC_WITHOUT.include?(it[:name]) }

    # Which budget, if any, leaves no room for another tool turn plus the final call the turn limit reserves.
    def budget_spent
      return "turns" if @turns >= @limits[:turns] - 1
      return "tool calls" if @tool_calls >= @limits[:tool_calls]
      "input tokens" if input_tokens >= @limits[:input_tokens]
    end

    def input_tokens = @usage[:input_tokens] + @usage[:cache_read_input_tokens] + @usage[:cache_creation_input_tokens]

    # The brief is the final response's text; interim narration from tool turns counts only when nothing followed it.
    def text = @texts.last.presence || @texts.reject(&:blank?).join("\n")

    # What the API accepts back of its own answer: the fields each block type is defined by, and nothing the
    # response adds for the reader (a tool_use's caller, a text block's citations), which a request refuses.
    # Thinking blocks go back whole: the signature is what lets the model continue them.
    REPLAYED = { text: %i[ type text ], tool_use: %i[ type id name input ], thinking: %i[ type thinking signature ], redacted_thinking: %i[ type data ] }.freeze

    def replay(block) = REPLAYED.key?(block.type) ? block.to_h.slice(*REPLAYED.fetch(block.type)) : block.to_h

    # Every tool_use id is answered in one user message, results first. A batch that would pass the call cap,
    # or one asked for after tools were withdrawn, runs nothing: each id gets an error result and the next call carries no tools.
    def answer(tool_uses, forced:)
      if forced || @tool_calls + tool_uses.size > @limits[:tool_calls]
        @capped_by ||= "tool calls"
        return tool_uses.map { |use| { type: :tool_result, tool_use_id: use.id, is_error: true, content: BUDGET_EXHAUSTED } }
      end
      tool_uses.map { |use| tool_result(use) }
    end

    def tool_result(use)
      @tool_calls += 1
      return { type: :tool_result, tool_use_id: use.id, is_error: true, content: "#{use.name} is not offered here" } unless tools.any? { it[:name] == use.name }
      result = Agent::Tools.call(use.name, use.input, transport: :scheduled, agent_run: run)
      @degraded_reasons << "#{use.name} failed: #{result.error}" unless result.ok?
      @degraded_reasons << "#{use.name} returned stale data" if result.ok? && stale?(result.value)
      text = result.text
      text = text.truncate_bytes(TOOL_RESULT_LIMIT, omission: "") + "\n[truncated at #{TOOL_RESULT_LIMIT / 1024} KB; ask for a narrower range or fewer rows]" if text.bytesize > TOOL_RESULT_LIMIT
      { type: :tool_result, tool_use_id: use.id, content: text, is_error: !result.ok? }
    end

    def stale?(value)
      case value
      when Hash then value["stale"] == true || value.values.any? { |v| stale?(v) }
      when Array then value.any? { |v| stale?(v) }
      else false
      end
    end

    # One retry at double the output budget when max_tokens cut into a tool call or the prose; the second time counts as capped.
    def retry_larger?
      return false if @retried
      @retried = true
      @messages.pop
      @texts.pop
      @max_tokens *= 2
      true
    end

    def elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started).seconds

    def finish(status, error: nil)
      if status != :failed && text.blank?
        status, error = :failed, "stopped by #{@stop || 'nothing'} with no text"
      end
      run.finish!(status, error: error, output_markdown: text.presence, stop_reason: @stop&.to_s, tool_turns: @turns, tool_calls_count: @tool_calls,
                  degraded: @degraded_reasons.any?, degraded_reasons: @degraded_reasons.uniq, transcript: Agent.serialize(@messages),
                  estimated_cost: Agent::Pricing.cost(Agent::MODEL, **@usage.slice(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)),
                  **@usage.slice(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens))
      run
    end
end
