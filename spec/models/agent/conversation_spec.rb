require "rails_helper"

RSpec.describe Agent::Conversation do
  let(:fake) { Agent::FakeAnthropic.instance }
  let(:run) { AgentRun.create!(kind: :morning_brief, market_date: Date.new(2026, 9, 1), status: :running, started_at: Time.current) }

  def text(string) = { type: :text, text: string }
  def tool_use(name, input = {}, id: "tu_#{SecureRandom.hex(3)}") = { type: :tool_use, id: id, name: name, input: input, caller: { type: :direct } } # caller: what the API adds to its answer
  def thinking = { type: :thinking, thinking: "considering", signature: "sig-abc" }
  def perform(agent_run = run) = described_class.new(agent_run).perform.reload
  def another_run(date) = AgentRun.create!(kind: :eod, market_date: date, status: :running, started_at: Time.current)

  it "answers every tool_use in one user message, results first, and round-trips thinking verbatim" do
    fake.enqueue(content: [ thinking, text("Looking."), tool_use("get_portfolio", id: "a"), tool_use("get_quotes", { symbols: [ "XYZ" ] }, id: "b") ], stop_reason: :tool_use)
    fake.enqueue(content: [ text("Brief: XYZ is protected.") ], stop_reason: :end_turn)
    perform
    expect(run).to have_attributes(status: "succeeded", tool_turns: 2, tool_calls_count: 2, stop_reason: "end_turn", output_markdown: "Brief: XYZ is protected.", error: nil)
    expect(run.tool_calls.pluck(:tool_name)).to match_array(%w[ get_portfolio get_quotes ])

    second = fake.requests.last
    expect(second[:messages][1][:content].first).to include(type: :thinking, signature: "sig-abc")
    replayed = second[:messages][1][:content].find { |b| b[:type] == :tool_use }
    expect(replayed.keys).to contain_exactly(:type, :id, :name, :input) # the API refuses its own caller field back (the 2026-09-02 morning brief)
    expect(second[:messages][2][:role]).to eq(:user)
    expect(second[:messages][2][:content].map { |b| b[:tool_use_id] }).to eq(%w[ a b ])
    expect(second[:messages][2][:content]).to all(include(type: :tool_result, is_error: false))
    expect(second[:tools].map { |t| t[:name] }).to eq(Agent::Tools.definitions(:scheduled).map { |t| t[:name] })
    expect(second[:system_]).to include("Every number you write comes from a tool result")
    expect(second[:system_]).to eq(fake.requests.first[:system_]) # the same bytes every turn, or the cache misses
    expect(run.transcript.last).to include("role" => "assistant")
  end

  it "sends the caching, timeout, and output budget the design calls for" do
    fake.enqueue(content: [ text("Brief.") ], stop_reason: :end_turn)
    perform
    request = fake.requests.last
    expect(request).to include(model: Agent::MODEL, max_tokens: Agent::Conversation::MAX_OUTPUT_TOKENS, cache_control: { type: :ephemeral }, tool_choice: { type: :auto },
                               request_options: { timeout: Agent::REQUEST_TIMEOUT })
  end

  it "sums usage across turns, cache fields included, and prices the run" do
    fake.enqueue(content: [ tool_use("get_setup_stats") ], stop_reason: :tool_use, usage: { input_tokens: 1000, cache_creation_input_tokens: 2000 })
    fake.enqueue(content: [ text("Brief.") ], stop_reason: :end_turn, usage: { input_tokens: 100, cache_read_input_tokens: 2000, output_tokens: 50 })
    perform
    expect(run).to have_attributes(input_tokens: 1100, cache_creation_input_tokens: 2000, cache_read_input_tokens: 2000, output_tokens: 350, model: Agent::MODEL)
    expect(run.estimated_cost).to eq(BigDecimal("0.0111")) # 1100×2 + 2000×2×1.25 + 2000×2×0.1 + 350×10, per million
  end

  it "marks the run degraded from tool errors and stale results, keeping the reasons" do
    fake.enqueue(content: [ tool_use("get_quotes", { symbols: [ "XYZ" ] }), tool_use("get_journal", { limit: "x" }) ], stop_reason: :tool_use)
    fake.enqueue(content: [ text("Brief.") ], stop_reason: :end_turn)
    Agent::MarketData.quotes([ "XYZ" ]) # warm the cache, then let it age past freshness with Schwab down
    travel 3.minutes
    Schwab::FakeClient.instance.enqueue(:quotes) { raise Schwab::ServerError.new("down", status: 503) }
    perform
    expect(run.degraded).to be(true)
    expect(run.degraded_reasons).to include("get_quotes returned stale data", a_string_starting_with("get_journal failed: bad arguments"))
  end

  it "runs nothing when a batch would pass the call cap, answers each id with an error, and makes one final call without tools" do
    stub_const("Agent::Conversation::MAX_TOOL_CALLS", 1)
    fake.enqueue(content: [ tool_use("get_portfolio", id: "a"), tool_use("get_setup_stats", id: "b") ], stop_reason: :tool_use)
    fake.enqueue(content: [ text("From what I have.") ], stop_reason: :end_turn)
    perform
    expect(run).to have_attributes(status: "capped", error: "budget spent: tool calls", tool_calls_count: 0, tool_turns: 2, output_markdown: "From what I have.")
    expect(ToolCall.count).to eq(0)
    final = fake.requests.last
    expect(final[:tool_choice]).to eq(type: :none)
    expect(final[:messages].last[:content]).to all(include(type: :tool_result, is_error: true, content: Agent::Conversation::BUDGET_EXHAUSTED))
  end

  it "reserves the last turn for a final call with no tools" do
    stub_const("Agent::Conversation::MAX_TURNS", 3)
    2.times { fake.enqueue(content: [ tool_use("get_setup_stats") ], stop_reason: :tool_use) }
    fake.enqueue(content: [ text("Done.") ], stop_reason: :end_turn)
    perform
    expect(run).to have_attributes(status: "capped", error: "budget spent: turns", tool_turns: 3, tool_calls_count: 2)
    expect(fake.requests.map { |r| r[:tool_choice] }).to eq([ { type: :auto }, { type: :auto }, { type: :none } ])
  end

  it "stops a model that keeps asking for tools after they were withdrawn" do
    stub_const("Agent::Conversation::MAX_TURNS", 3)
    3.times { fake.enqueue(content: [ tool_use("get_setup_stats") ], stop_reason: :tool_use, ignoring_tool_choice: true) }
    expect(perform).to have_attributes(status: "failed", error: "3 turns passed without a final answer", tool_calls_count: 2)
  end

  it "retries max_tokens once at double the budget, dropping only the cut response, then counts a second one as capped" do
    fake.enqueue(content: [ text("Working."), tool_use("get_setup_stats") ], stop_reason: :tool_use)
    fake.enqueue(content: [ text("half a "), tool_use("get_portfolio") ], stop_reason: :max_tokens)
    fake.enqueue(content: [ text("whole brief, cut") ], stop_reason: :max_tokens)
    perform
    expect(run).to have_attributes(status: "capped", stop_reason: "max_tokens", error: "budget spent: output tokens", output_markdown: "whole brief, cut", tool_calls_count: 1)
    expect(fake.requests.map { |r| r[:max_tokens] }).to eq([ 8192, 8192, 16384 ])
    expect(fake.requests.last[:messages].size).to eq(3) # user, assistant tool turn, its results: the cut response is gone
  end

  it "fails a refusal keeping its text, and an empty answer with a reason" do
    fake.enqueue(content: [ text("I cannot") ], stop_reason: :refusal)
    expect(perform).to have_attributes(status: "failed", error: a_string_including("refusal"), output_markdown: "I cannot")

    fake.enqueue(content: [], stop_reason: :end_turn)
    expect(perform(another_run(Date.new(2026, 9, 1)))).to have_attributes(status: "failed", error: "the model ended without writing anything")

    fake.enqueue(content: [ tool_use("get_setup_stats") ], stop_reason: :max_tokens)
    fake.enqueue(content: [], stop_reason: :max_tokens)
    expect(perform(another_run(Date.new(2026, 9, 2)))).to have_attributes(status: "failed", error: "stopped by max_tokens with no text")
  end

  it "turns an SDK error into a failed run the job can still email" do
    fake.enqueue { raise Anthropic::Errors::RateLimitError.new(url: URI("https://api.anthropic.com/v1/messages"), status: 429, headers: {}, body: nil, request: nil, response: nil, message: "rate limited") }
    expect(perform).to have_attributes(status: "failed", error: a_string_including("Anthropic RateLimitError"))
    fake.enqueue { raise Anthropic::Errors::ConversionError.new(on: Integer, method: :dump, target: "x", value: nil) }
    expect(perform(another_run(Date.new(2026, 9, 1)))).to have_attributes(status: "failed", error: a_string_including("Anthropic ConversionError"))
  end

  it "truncates an oversized tool result with a note" do
    stub_const("Agent::Conversation::TOOL_RESULT_LIMIT", 64)
    fake.enqueue(content: [ tool_use("get_setup_stats") ], stop_reason: :tool_use)
    fake.enqueue(content: [ text("ok") ], stop_reason: :end_turn)
    perform
    expect(fake.requests.last[:messages].last[:content].first[:content]).to include("[truncated at 0 KB")
  end

  it "fails when the wall-clock deadline passes, without a misleading stop reason" do
    stub_const("Agent::Conversation::DEADLINE", 0.seconds)
    expect(perform).to have_attributes(status: "failed", error: a_string_including("deadline"), stop_reason: nil)
  end

  it "records an unexpected exception on the row and re-raises so the queue sees it" do
    allow_any_instance_of(Agent::Context).to receive(:user_prompt).and_raise("template broke")
    expect { described_class.new(run).perform }.to raise_error(RuntimeError, "template broke")
    expect(run.reload).to have_attributes(status: "failed", error: "RuntimeError: template broke")
  end
end
