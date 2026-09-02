require "rails_helper"

RSpec.describe Agent::Tools do
  it "exposes the read tools to both transports and the write tool to the interactive one only" do
    reads = %w[ get_portfolio get_account_health get_quotes get_price_history get_journal get_setup_stats get_risk_rules evaluate_hypothetical_order ]
    expect(described_class.for(:mcp).map(&:tool_name)).to match_array(reads + %w[ propose_order ])
    expect(described_class.for(:scheduled).map(&:tool_name)).to match_array(reads)
    expect(described_class.for(:scheduled)).to all(be_read_only)
    expect(described_class.definitions(:scheduled).first).to include(:name, :description, :input_schema)
  end

  it "declares required inputs and closed output schemas" do
    expect(Agent::Tools::GetQuotes.input_schema).to include(required: [ "symbols" ], additionalProperties: false)
    expect(Agent::Tools::GetPortfolio.output_schema).to include(additionalProperties: false)
    expect(Agent::Tools::GetPortfolio.output_schema[:required]).to include("state", "positions", "open_risk")
  end

  it "refuses to define an unattended tool that is not read-only" do
    expect {
      Class.new(Agent::Tool) { tool description: "x", output: {}, read_only: false, scheduled: true }
    }.to raise_error(ArgumentError, /read-only/)
  end

  it "keeps a tool marked scheduled: false out of the scheduled transport" do
    interactive_only = Class.new(Agent::Tool) { tool description: "x", output: {}, scheduled: false }
    allow(described_class).to receive(:all).and_return([ interactive_only, Agent::Tools::GetRiskRules ])
    expect(described_class.for(:scheduled)).to eq([ Agent::Tools::GetRiskRules ])
    expect(described_class.for(:mcp)).to include(interactive_only)
  end

  it "dispatches with telemetry" do
    result = described_class.call("get_risk_rules", {}, transport: :mcp)
    expect(result.ok?).to be(true)
    expect(result.value).to include("available" => false)
    expect(result.text).to include('"available":false')
    expect(ToolCall.last).to have_attributes(tool_name: "get_risk_rules", transport: "mcp", error: nil, arguments: {})
    expect(ToolCall.last.duration_ms).to be >= 0
  end

  it "records a denied call, distinguishing an unknown tool from one the transport may not use" do
    expect(described_class.call("nope", {}, transport: :mcp).error).to eq("unknown tool nope")
    expect(ToolCall.last).to have_attributes(tool_name: "nope", error: "unknown tool nope")

    interactive_only = Class.new(Agent::Tool) { tool description: "x", output: {}, scheduled: false }
    allow(interactive_only).to receive(:name).and_return("Agent::Tools::OnlyMcp")
    allow(described_class).to receive(:all).and_return([ interactive_only ])
    expect(described_class.call("only_mcp", {}, transport: :scheduled).error).to eq("only_mcp is not available on the scheduled transport")
    expect(ToolCall.last).to have_attributes(tool_name: "only_mcp", transport: "scheduled")
  end

  it "validates arguments against the schema on every transport and records the failure" do
    bad = described_class.call("get_quotes", { symbols: [] }, transport: :scheduled)
    expect(bad.ok?).to be(false)
    expect(bad.error).to include("bad arguments")
    expect(ToolCall.last).to have_attributes(error: bad.error, arguments: { "symbols" => [] })
    expect(described_class.call("get_quotes", {}, transport: :scheduled).error).to include("symbols")
    expect(described_class.call("get_journal", { limit: "ten" }, transport: :scheduled).error).to include("bad arguments")
    expect(described_class.call("get_journal", { offset: -1 }, transport: :scheduled).error).to include("bad arguments")
    expect(described_class.call("get_risk_rules", { extra: 1 }, transport: :scheduled).error).to include("bad arguments")
  end

  it "turns a Schwab rate limit into a result carrying retry_after" do
    Schwab::FakeClient.instance.enqueue(:quotes) { raise Schwab::RateLimited.new("busy", retry_after: 30) }
    limited = described_class.call("get_quotes", { symbols: [ "XYZ" ] }, transport: :mcp)
    expect(limited.ok?).to be(false)
    expect(limited.retry_after).to eq(30)
    expect(limited.error).to include("30 seconds")
  end

  it "turns a missing token into a re-authentication message" do
    allow(Schwab).to receive(:client).and_raise(Schwab::NoUsableToken, "no usable Schwab token")
    expect(described_class.call("get_quotes", { symbols: [ "XYZ" ] }, transport: :mcp).error).to include("re-authentication")
  end

  it "reports an unexpected exception under the tool's name and never raises, even from the base class" do
    allow_any_instance_of(Agent::Tools::GetRiskRules).to receive(:call).and_raise(NotImplementedError, "boom")
    expect(Rails.error).to receive(:report).with(kind_of(NotImplementedError), hash_including(context: { tool: "get_risk_rules" }))
    result = described_class.call("get_risk_rules", {}, transport: :mcp)
    expect(result.error).to eq("get_risk_rules failed: NotImplementedError")
    expect(ToolCall.last.error).to eq(result.error)
  end

  it "serializes money as decimal strings and times in New York" do
    expect(Agent.serialize(BigDecimal("51.18"))).to eq("51.18")
    expect(Agent.serialize(Time.utc(2026, 9, 8, 20))).to eq("2026-09-08T16:00:00-04:00")
    expect(Agent.serialize({ a: [ :sym, Date.new(2026, 9, 8) ] })).to eq("a" => [ "sym", "2026-09-08" ])
  end
end

RSpec.describe Agent::Tool, "audited tools" do
  it "audits every call to an audited tool, requires it of any tool that writes, and keeps writes off the scheduled transport" do
    writer = Class.new(Agent::Tool) do
      tool description: "x", output: { ok: { type: "boolean" } }, read_only: false, scheduled: false
      def call = { ok: true }
    end
    allow(writer).to receive(:name).and_return("Agent::Tools::WriteThing")
    allow(Agent::Tools).to receive(:all).and_return([ writer ])
    expect(writer).to be_audited
    expect(Agent::Tools.for(:scheduled)).to be_empty
    expect(Agent::Tools.call("write_thing", {}, transport: :mcp).ok?).to be(true)
    expect(AuditEvent.find_by(kind: "agent_tool_used")).to have_attributes(actor: "agent", data: hash_including("tool" => "write_thing", "transport" => "mcp", "arguments" => {}, "ok" => true, "tool_call_id" => ToolCall.last.id))
    expect(Agent::Tools.call("write_thing", { extra: 1 }, transport: :mcp).ok?).to be(false)
    expect(AuditEvent.where(kind: "agent_tool_used").last).to have_attributes(reason: a_string_including("bad arguments"), data: hash_including("ok" => false))
    expect(Agent::Tools.call("write_thing", {}, transport: :scheduled).error).to include("not available")
    expect { Class.new(Agent::Tool) { tool description: "x", output: {}, read_only: false, scheduled: false, audited: false } }.to raise_error(ArgumentError, /audited/)
  end
end
