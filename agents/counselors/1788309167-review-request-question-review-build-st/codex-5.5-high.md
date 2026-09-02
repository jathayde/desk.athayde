**Verdict**

Step 8 is close on the MCP transport shape, but it is not ready. The biggest problems are in the wrapper and contracts, not the gem mount.

**Critical Findings**

1. [app/models/agent/tools.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/tools.rb:40): unexpected tool exceptions can become protocol errors and lose telemetry. The rescue block references undefined `name`, then the `ensure` returns `result`, which may be nil. In MCP, [app/models/agent/mcp_server.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/mcp_server.rb:16) then calls `result.ok` and the gem turns that into `-32603`. Fix the rescue to use `tool.tool_name`, avoid `return` from `ensure`, and make telemetry persistence unable to mask the tool result.

2. [app/models/agent/market_data.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/market_data.rb:30): market-data calls spend the Schwab budget twice. `Agent::MarketData` takes from the 70/min share, then [app/models/schwab/client.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/client.rb:162) takes again from the global 100/min key. That means MCP effectively gets about 35/min and also inflates sync pressure. Add a client-level budget override or make the lower-share take the only take for these calls.

3. [app/controllers/mcp_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/mcp_controller.rb:15): bearer auth does not require the `Bearer` scheme. `delete_prefix("Bearer ")` leaves non-bearer headers unchanged, so `Authorization: <token>` is accepted. Parse the scheme explicitly and reject anything but exactly bearer auth.

**Major Findings**

4. [app/models/agent/tool.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/tool.rb:8): input schemas do not set `required`, so the MCP gem cannot advertise or preflight required arguments like `symbols` and `symbol`. Missing required fields fall through to Ruby keyword errors.

5. [app/models/agent/tool.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/tool.rb:9): output schemas violate the plan. They set `additionalProperties: true`, most arrays have no `items`, and [app/models/agent/mcp_server.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/mcp_server.rb:8) leaves `validate_tool_call_results` off. The schema is mostly decorative. Make outputs closed, describe nested objects, and enable result validation at least in specs.

6. [app/models/agent/mcp_server.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/mcp_server.rb:18): MCP tool failures drop `retry_after`. `Agent::Tools::Result` carries it, but the MCP response only returns plain text. Rate-limit errors should return structured JSON text or `_meta` with `retry_after`.

7. [app/models/agent/tools/get_quotes.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/tools/get_quotes.rb:13): all-invalid symbols become `Schwab unavailable`. That is wrong and loses `invalid_symbols`. Return `{ quotes: [], invalid_symbols: [...] }` or a user-input tool error, not a Schwab availability error.

8. [app/models/agent/tools/get_risk_rules.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/tools/get_risk_rules.rb:7): the tool says Phase 1 rules are unavailable, but it returns `RiskRule.active`. Once any rows exist, Claude sees `available: false` plus real rules. Return an empty list in Phase 1 or set `available: true`.

**Transport Notes**

The current controller uses `StreamableHTTPTransport` correctly enough for the intended stateless JSON path: Accept/Content-Type, body cap, protocol-version checks, notifications, GET, DELETE, and modern `server/discover` are handled by the gem. The weak spot is [app/controllers/mcp_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/mcp_controller.rb:7): it treats a Rack app triple as a controller response. Current flags avoid most streaming bodies, but mounting the transport as Rack is still cleaner and less fragile.

Claude app connection still depends on the org-gated static request-header UI. If Claude probes before sending the configured bearer, this endpoint returns 401 for everything because of [app/controllers/mcp_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/mcp_controller.rb:4). Bearer-only is fine only after that UI is verified; otherwise OAuth/lazy auth remains open.

**Missing Specs**

Add specs for `notifications/initialized` returning 202, modern `server/discover` with `MCP-Protocol-Version: 2026-07-28`, DELETE behavior, bad Accept/Content-Type, 413 body cap, invalid protocol header, host rejection, non-`Bearer` Authorization rejection, forced unexpected tool exception, all-invalid quotes, retry-after propagation, and output-schema validation. Current specs do not cover most of the connection lifecycle.

I did not run the test suite; this workspace is read-only, and the default `bundle` path also fails on missing Bundler 4.0.4. I inspected the installed local `mcp-1.4.0` gem source directly.
