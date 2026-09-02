# Second Opinion Request

## Question
# Review Request

## Question
Review build step 8 of Phase 1: the MCP server and the agent tool registry, built to the design you reviewed (gem transport mounted stateless with allowed_hosts, bearer-only with a JSON 401 and WWW-Authenticate, structured content, one dispatch wrapper with telemetry, cached market data with a budget share, tools wrapping the Dashboard read model). Verify it against the MCP spec and the `mcp` gem 1.4 as actually implemented, and find what breaks when the Claude app connects.

## Context

### Files to Review
Uncommitted on top of commit e7e760d; `git status --porcelain` lists them.
- @app/models/agent.rb @app/models/agent/tool.rb @app/models/agent/tools.rb @app/models/agent/market_data.rb @app/models/agent/mcp_server.rb
- @app/models/agent/tools/get_portfolio.rb @app/models/agent/tools/get_account_health.rb @app/models/agent/tools/get_quotes.rb @app/models/agent/tools/get_price_history.rb @app/models/agent/tools/get_journal.rb @app/models/agent/tools/get_setup_stats.rb @app/models/agent/tools/get_risk_rules.rb
- @app/controllers/mcp_controller.rb @config/routes.rb @Gemfile
- Specs: @spec/models/agent/tools_spec.rb @spec/models/agent/tool_outputs_spec.rb @spec/requests/mcp_spec.rb
- Supporting: @app/models/dashboard.rb @app/models/schwab/rate_budget.rb @app/models/schwab/client.rb

### The design it implements
- @docs/phase-1-plan.md §3 "Tool surface", "MCP server", "Connector auth"
- Your previous design review (find the directory by grepping agents/counselors/*/prompt.md for "build step 8")

## Instructions
You are providing an independent review. Be critical and thorough.
- Trace a Claude app connection end to end through McpController and the gem's StreamableHTTPTransport: Accept and Content-Type handling, initialize under the 2025 handshake and the 2026-07-28 stateless lifecycle, notifications/initialized (202), tools/list, tools/call, GET and DELETE, the protocol-version header, allowed_hosts against desk.athayde.com and the request host, the 64 KB body cap, and what setting response_body from the Rack triple does with a streaming body
- Check the bearer check for timing safety, logging, and the 401 shape; check the rate limit and its cache store in production
- Check MCP::Tool.define usage: the block signature the gem calls with (keyword arguments plus server_context), output_schema validation when validate_tool_call_results is off, annotations mapping, and what happens when Agent::Tools.call returns a failure
- Check each tool's schema and output against the plan: additionalProperties, pagination, symbol limits, invalid symbols, stale flags, null-versus-zero risk, decimal strings, timestamps, no account hash or raw payload or email
- Check Agent::MarketData: cache keys, read_multi semantics with memory store versus Solid Cache, the fetched_at comparison, the budget share, rate-limit propagation, price history range mapping against Schwab::Client#price_history
- Check the dispatch wrapper: ensure-with-return, exception classes rescued, what the ToolCall row records, argument normalization (symbol versus string keys from the gem and from the Anthropic SDK)
- Flag what step 9 will need from the registry that is still missing
- Flag missing specs; say which earlier concerns are closed and which remain
- Be direct and opinionated; do not hedge; order by severity with file paths

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
