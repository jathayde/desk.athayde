require "rails_helper"

RSpec.describe "MCP endpoint" do
  let(:token) { Rails.application.credentials.dig(:mcp, :bearer_token) }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" } }

  def rpc(method, params = {}, id: 1, headers: self.headers) = post("/mcp", params: { jsonrpc: "2.0", id: id, method: method, params: params }.compact.to_json, headers: headers)

  it "rejects a missing, wrong, or non-bearer credential with a JSON 401 and WWW-Authenticate" do
    post "/mcp", params: {}.to_json, headers: headers.merge("Authorization" => "Bearer nope")
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to eq('Bearer error="invalid_token"')
    expect(response.parsed_body).to eq("error" => "invalid_token")
    post "/mcp", params: {}.to_json, headers: headers.except("Authorization")
    expect(response).to have_http_status(:unauthorized)
    post "/mcp", params: {}.to_json, headers: headers.merge("Authorization" => token)
    expect(response).to have_http_status(:unauthorized)
    post "/mcp", params: {}.to_json, headers: headers.merge("Authorization" => "Basic #{Base64.strict_encode64("x:#{token}")}")
    expect(response).to have_http_status(:unauthorized)
  end

  it "accepts the bearer scheme case-insensitively" do
    rpc("tools/list", headers: headers.merge("Authorization" => "bearer #{token}"))
    expect(response).to have_http_status(:ok)
  end

  it "lists the tools with required inputs, closed schemas, and read-only annotations" do
    rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } })
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("result", "capabilities").keys).to eq([ "tools" ])
    rpc("notifications/initialized", id: nil)
    expect(response).to have_http_status(:accepted)
    expect(response.body).to be_blank
    rpc("tools/list")
    tools = response.parsed_body.dig("result", "tools")
    expect(tools.map { |t| t["name"] }).to include("get_portfolio", "get_journal")
    quotes = tools.find { |t| t["name"] == "get_quotes" }
    expect(quotes.dig("inputSchema", "required")).to eq([ "symbols" ])
    expect(quotes.dig("inputSchema", "additionalProperties")).to be(false)
    expect(quotes.dig("outputSchema", "additionalProperties")).to be(false)
    expect(quotes.dig("annotations", "readOnlyHint")).to be(true)
    expect(quotes.dig("annotations", "destructiveHint")).to be(false)
  end

  it "calls a tool and returns structured content plus text, writing a tool_calls row" do
    rpc("tools/call", { name: "get_risk_rules", arguments: {} })
    expect(response).to have_http_status(:ok)
    result = response.parsed_body["result"]
    expect(result["structuredContent"]).to include("available" => false)
    expect(JSON.parse(result["content"].first["text"])).to include("available" => false)
    expect(ToolCall.last).to have_attributes(transport: "mcp", tool_name: "get_risk_rules")
  end

  it "answers get_portfolio before the first sync with a result that passes its own output schema" do
    rpc("tools/call", { name: "get_portfolio", arguments: {} })
    expect(response.parsed_body["result"]).to include("structuredContent" => hash_including("state" => "not_connected", "open_risk" => nil))
    expect(response.parsed_body["result"]["isError"]).to be(false)
  end

  it "turns a tool failure into a tool error carrying retry_after, not a protocol error" do
    rpc("tools/call", { name: "get_quotes", arguments: { symbols: [] } })
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["result"]["isError"]).to be(true)
    expect(response.parsed_body["result"]["content"].first["text"]).to include("symbols")

    Schwab::FakeClient.instance.enqueue(:quotes) { raise Schwab::RateLimited.new("busy", retry_after: 30) }
    rpc("tools/call", { name: "get_quotes", arguments: { symbols: [ "XYZ" ] } })
    expect(response.parsed_body["result"]).to include("isError" => true, "_meta" => { "retry_after" => 30 })
  end

  it "rejects arguments the schema does not allow as a tool error" do
    rpc("tools/call", { name: "get_risk_rules", arguments: { extra: 1 } })
    expect(response.parsed_body["result"]["isError"]).to be(true)
    rpc("tools/call", { name: "get_quotes", arguments: {} })
    expect(response.parsed_body["result"]["content"].first["text"]).to eq("Missing required arguments: symbols")
  end

  it "answers GET with 405 and DELETE with 200 in stateless mode" do
    get "/mcp", headers: headers
    expect(response).to have_http_status(:method_not_allowed)
    delete "/mcp", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "refuses the wrong Accept, Content-Type, protocol version, and an oversized body" do
    rpc("tools/list", headers: headers.merge("Accept" => "text/html"))
    expect(response).to have_http_status(:not_acceptable)
    rpc("tools/list", headers: headers.merge("Content-Type" => "text/plain"))
    expect(response).to have_http_status(:unsupported_media_type)
    rpc("tools/list", headers: headers.merge("MCP-Protocol-Version" => "1999-01-01"))
    expect(response).to have_http_status(:bad_request)
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list", params: { pad: "x" * 65.kilobytes } }.to_json, headers: headers
    expect(response).to have_http_status(:content_too_large)
  end

  it "rate limits the door at 60 requests a minute" do
    Rails.cache.clear
    60.times { rpc("tools/list") }
    expect(response).to have_http_status(:ok)
    rpc("tools/list")
    expect(response).to have_http_status(:too_many_requests)
  end
end
