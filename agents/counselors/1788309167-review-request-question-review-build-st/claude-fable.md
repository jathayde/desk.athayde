# Step 8 build review: MCP server and agent tool registry

Verified against `mcp` 1.4.0 source at `~/.local/share/mise/installs/ruby/3.4.9/lib/ruby/gems/3.4.0/gems/mcp-1.4.0`, the MCP 2025-11-25 tools spec, the Ruby SDK transport docs, and Claude's connector docs.

## Verdict

The transport integration is right. The controller hands the raw Rack env to the gem's `StreamableHTTPTransport`, stateless with JSON responses, and every path the gem can take in that configuration returns an Array body, so `self.response_body = body` is safe and actually handles the 202 empty body better than the SDK docs' `render json: body.first` pattern (which would render the string `null`). The legacy handshake, `notifications/initialized`, `tools/list`, `tools/call`, GET 405, DELETE 200, protocol-version header, 64 KB cap, Accept and Content-Type checks all work as designed.

Three things will bite when Claude connects or shortly after: the declared output schemas are violated on ordinary paths, the Schwab budget share double-counts, and decision 0.8 is still unverified. Details in severity order.

## Blocking

### 1. Output schemas are violated on real paths

`app/models/agent/tool.rb:9` declares an `output_schema` for every tool and `app/models/agent/mcp_server.rb:13` sends it in `tools/list`. The spec is explicit: "If an output schema is provided: Servers MUST provide structured results that conform to this schema. Clients SHOULD validate structured results against this schema." The reference TypeScript client does validate and throws `McpError` on mismatch.

Violations today:

- `get_portfolio.rb:6` declares `open_risk: { type: "object" }`; line 9 returns `open_risk: nil` whenever state is not `:ready`. That is the first response Claude gets on a fresh install.
- `get_account_health.rb:5` declares `equity: { type: "object" }`; `equity_hash` returns nil before the first balance.
- `get_price_history.rb:6` declares `previous_close: { type: "string" }`; `Decimal.parse` returns nil when Schwab omits `previousClose`.

The gem never catches this because `validate_tool_call_results` defaults to false (`configuration.rb:57`) and the build leaves it there.

Fix: either write honest schemas (`type: ["object", "null"]`, and list every top-level key you actually emit) or stop passing `output_schema:` to `MCP::Tool.define` until you do. A half schema is worse than none. Whichever you choose, set `validate_tool_call_results: true` in test so `spec/requests/mcp_spec.rb` fails on drift, and add a "before first sync" case to that spec. Note the plan text says `additionalProperties: false` on every schema; the output schema uses `true` (`tool.rb:9`). Pick one and make the plan match.

### 2. The 70/min budget share double-counts every market-data call

`app/models/agent/market_data.rb:30` and `:50` call `Schwab::RateBudget.take!(budget: 70)`, then `Schwab.client(wait: false)` runs `Schwab::Client#dispatch`, which calls `RateBudget.take!` again at `app/models/schwab/client.rb:162` with the default budget of 100. Both hit the same cache key. Every quote or history call costs two units of the shared 100/min counter. The intended effect (reserve 30 for sync) is inverted: a chatty session burns the sync budget twice as fast and starts failing MCP at 35 real calls. The FakeClient has no `dispatch`, so no spec can see this.

Fix: give `Schwab::Client.new` a `budget:` keyword that `dispatch` passes to `take!`, thread it through `Schwab.client(budget: 70)`, and delete the two `take!` calls in `MarketData`. One increment per request, one place.

### 3. Decision 0.8 is still an assumption

`docs/phase-1-plan.md:227` says step 8 runs "after decision 0.8 is verified". Nothing in this diff records that the connector dialog exposed a request-headers section for this org. If it does not, the very first probe gets a 401 with no `resource_metadata`, Claude then looks for `/.well-known/oauth-protected-resource/mcp`, gets a Rails 404, and reports "Couldn't reach the MCP server" (this is the documented failure path). The code is correct for the bearer-first design; the risk is that the design's precondition is unconfirmed. Confirm it before calling the step done, or note in the commit that OAuth is the next step if it fails.

## High

### 4. `allowed_hosts` is a tautology

`app/controllers/mcp_controller.rb:25` passes `config.hosts + [request.host]`. The gem matches the bare hostname of `HTTP_HOST` against the list (`streamable_http_transport.rb:1845-1856`), and `request.host` is that same hostname, so every request passes. The gem's Host check is disabled while looking enabled. Production is still protected because Rails `HostAuthorization` enforces `desk.athayde.com` first, so this is not a hole, but it misleads the next reader.

Fix: pass `dns_rebinding_protection: false` with a one-line comment that Rails host authorization owns this check. That also removes the Origin check (`:1860-1867`), which returns 403 to any browser client whose Origin is not `desk.athayde.com`. Claude's server-side client sends no Origin so it passes today, but MCP Inspector in a browser would not. If you keep the gem's check, pass `allowed_origins: ["https://claude.ai"]` and add `www.example.com` in test instead of `request.host`.

### 5. No `required` in any input schema

`tool.rb:8` builds `{ type: object, properties:, additionalProperties: false }` and never emits `required`. The gem's missing-argument check (`server.rb:1235`) reads only `required`, so `get_quotes` with no `symbols` passes the gem and lands on `tool.new.call()` as a Ruby `ArgumentError`, which `tools.rb:38` turns into "bad arguments: missing keyword: :symbols". It works by accident and Claude never learns from `tools/list` which parameters are mandatory. The Anthropic Messages API definition step 9 reuses has the same gap. Add a `required:` list to `tool` and put it in both schemas.

## Medium

### 6. Dispatch wrapper details

`app/models/agent/tools.rb`:

- Line 41: `context: { tool: name }` resolves `name` to `Module#name`, so every report says `"Agent::Tools"`. Use `tool.tool_name`. The exception reporter in `mcp_server.rb:8` also discards the gem's context hash; pass it through.
- Lines 43-47: `return result` inside `ensure` swallows non-`StandardError` exceptions (Interrupt, NoMemoryError) and, if `record.save!` raises, the method raises despite the "never raises" contract. If `ToolCall.new` or `arguments.to_h` raises, `record` and `started` are nil and the ensure masks the original with a NoMethodError. Build the record and timer above the `begin`, assign `result` in every rescue branch, drop the `return`, and let the method's value fall out naturally.
- No schema validation for `:scheduled`. MCP gets json_schemer through the gem; the scheduled transport gets only Ruby keyword errors. `limit: "abc"` or `symbols: "AAPL"` reach the tool, and a negative `offset` (`get_journal.rb:22`) becomes a Postgres error reported as "get_journal failed: ActiveRecord::StatementInvalid". Step 9 feeds model output straight in. Validate in `dispatch` with `MCP::Tool::InputSchema#validate_arguments` (already loaded) so both transports share one gate, and clamp `offset`.
- Argument keys: the gem parses with `symbolize_names: true` and `call_tool_with_args` (`server.rb:1582`) transforms top-level keys to symbols, so the block's `**arguments` is symbol-keyed. `deep_symbolize_keys` at line 31 covers the Anthropic SDK's string keys. Correct. The block signature `|server_context: nil, **arguments|` is safe: `accepts_server_context?` (`server.rb:1569`) passes only `server_context:` plus the tool arguments, nothing else.

### 7. `get_quotes` mislabels an argument problem as an outage

`get_quotes.rb:13` raises `Schwab::RequestError` when every symbol is invalid, which `tools.rb:37` renders as "Schwab unavailable: no valid symbols in NOPE". That is a bad-argument error; raise `ArgumentError`. Separately, when Schwab is down and a symbol has no cache, `market_data.rb:16-19` drops it silently: not in `quotes`, not in `invalid_symbols`. Report those symbols explicitly so the agent knows what it did not get.

### 8. Rails parses the body before the bearer check and before the gem's cap

`ActionController::Instrumentation` computes `request.filtered_parameters` for the log line before `before_action` runs, which JSON-parses the whole body with no size limit. Malformed JSON becomes a Rails 400 rather than the gem's JSON-RPC parse error, and the 64 KB cap only guards the gem's second read. Single-user app, obscure path, so low risk, but set `client_max_body_size` explicitly in the dokku nginx config and know that the cap is not what you think it is.

### 9. Response size

`mcp_server.rb:17` sends the JSON twice (text block plus `structuredContent`). Claude.ai truncates tool results around 150,000 characters. `get_journal` at `limit: 200` with `include_legs` is roughly 240,000 characters. Either cap `MAX_LIMIT` at 100 or drop `include_legs` from the text block above some size.

## Low

- `mcp_controller.rb:15`: `delete_prefix("Bearer ")` is case-sensitive; the scheme is case-insensitive per RFC 7235. Claude sends the header verbatim as typed, so it works. The explicit bytesize check is redundant with `secure_compare`, harmless. Nothing logs the header and the 401 body echoes nothing. Timing is fine.
- `rate_limit` is declared before `require_bearer`, so it runs first, keyed by `remote_ip`, backed by Solid Cache in production (which supports `increment`). Fine.
- `mcp_server.rb:6`: default capabilities advertise `prompts`, `resources`, and `logging` with `listChanged: true`. Claude calls `prompts/list` and `resources/list` at connect and gets empty lists, so nothing breaks, but stateless mode cannot send `listChanged`. Pass `capabilities: { tools: {} }`.
- Cache round-trip: entries hold BigDecimal, `TimeWithZone`, and symbol keys. Solid Cache's default (Marshal via the 7.1 format) handles them; `read_multi` returns hits only under both stores; the `fetched_at` comparison and `stale` flag are correct. If anyone switches to `serializer: :message_pack` this silently breaks. One comment on `KEEP` is enough.
- Price history range mapping against `Schwab::Client#price_history` is valid for all six presets (month 1/3/6 daily, year 1 daily, year 2/5 weekly).
- The Playwright "MCP 401 page" scenario still appears in `docs/phase-1-plan.md:204` though the design review dropped it. Remove the line.
- Claude's connector docs list support through the 2025-11-25 spec, so the legacy handshake is the path that will run. The 2026-07-28 modern path is correctly wired but untested by specs.

## Missing specs

- Output schema conformance (item 1) with `validate_tool_call_results: true` and a pre-sync `get_portfolio` call through the endpoint.
- `notifications/initialized` returns 202 with an empty body.
- DELETE returns 200; GET is exactly 405 (the spec allows 400 or 405).
- Wrong Accept (406), wrong Content-Type (415), a body over 64 KB (413), an unsupported `MCP-Protocol-Version` (400).
- A `tools/call` with `MCP-Protocol-Version: 2026-07-28`, `Mcp-Method`, `Mcp-Name`, and the `_meta` envelope.
- The budget double-count (item 2). Needs a `Schwab::Client` spec with a stubbed HTTP layer counting `RateBudget` increments per call.
- Expired token path: the plan promises "when the token is expired returns the cached value with `stale: true`". With the fake adapter `Schwab.client` never consults the token, so this is untested. Stub `Schwab.client` to raise `NoUsableToken` and assert the stale answer.
- `tool_calls.arguments` records what was passed.
- `tools_spec.rb:6` asserts `for(:scheduled) == for(:mcp)`. Add a negative case: a non-scheduled tool is absent from `:scheduled`.

## Earlier concerns: closed and open

Closed: transport instead of `handle_json`; stateless; JSON 401 with `WWW-Authenticate` and no `resource_metadata`; `ActionController::API`; tool exceptions never reach the transport; long-expiry cache with `fetched_at`; Dashboard wrapped, and the `MarketDay.session_open?` Schwab-hit concern is closed because `Dashboard` now uses `known_session_open?`; structured content plus text; decimal strings; New York timestamps; no `raw`, hash, or email, with the leak spec in place; annotations; `additionalProperties: false` on inputs; argument validation on; pagination; `invalid_symbols`; enum range; `available: false`; gem-free registry; one dispatch entry point; boot-time read-only invariant; `tool_calls` schema needs no migration.

Open: budget share (item 2); `required` (item 5); schema validation in the wrapper (item 6); decision 0.8 (item 3). Codex's `{value, as_of, stale, source}` per number and cursor pagination were not adopted; per-row `as_of` and `stale` plus offset paging are fine for Phase 1.

## What step 9 still needs from the registry

- `required` in `definition` (item 5).
- Validation in `dispatch` (item 6) so the runtime does not need its own.
- One place that turns a `Result` into the text the Messages API `tool_result` carries. `mcp_server.rb:17-19` builds that text inline; add `Result#text` and use it from both adapters.
- `retry_after` on a rate-limited `Result` needs a runtime policy (skip the tool for the rest of the run, never sleep). Decide it in step 9, but the field is there.
- `Agent::Tools.for(:scheduled)` and `definitions(:scheduled)` are ready; `agent_run:` plumbing is ready; no timeout per call exists, which is acceptable with `wait: false` and Schwab's 5 s open and 20 s read limits.

Sources: [MCP 2025-11-25 tools spec](https://modelcontextprotocol.io/specification/2025-11-25/server/tools), [Ruby SDK transports](https://ruby.sdk.modelcontextprotocol.io/server/transports/), [Claude connectors: building](https://claude.com/docs/connectors/building), [Claude connectors: troubleshooting](https://claude.com/docs/connectors/building/troubleshooting), [TypeScript SDK structuredContent validation issue](https://github.com/modelcontextprotocol/typescript-sdk/issues/911), [TypeScript SDK isError and structuredContent](https://github.com/modelcontextprotocol/typescript-sdk/issues/654).
