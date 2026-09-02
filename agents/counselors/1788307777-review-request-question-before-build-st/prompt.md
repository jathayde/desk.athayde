# Second Opinion Request

## Question
# Review Request

## Question
Before build step 8 (the MCP server with read-only tools over HTTPS with bearer auth, and the shared tool registry the scheduled runtime will reuse in step 9) is written, review the design against the PRD and the current MCP specification, and find what will break when the Claude app connects.

## Context

### PRD and plan
- @docs/artifacts/investment-copilot-prd.md §5.5 (read tools: get_portfolio, get_account_health, get_quotes, get_price_history, get_journal, get_setup_stats, get_risk_rules; evaluate_hypothetical_order omitted until Phase 2; write tools absent), §5.5a (one tool surface, two transports; unattended runs read-only with a hard turn cap), §4 (why an MCP server)
- @docs/phase-1-plan.md §3 (tool surface with permission metadata, MCP server, scheduled runtime), §0 decision 8 (bearer header availability in the Claude app is unverified; fallback is a minimal OAuth 2.1 authorization-code + PKCE endpoint issuing the same bearer after magic-link login), §1 row 20 (tool_calls telemetry table)

### What exists
- Gems: the official `mcp` Ruby SDK (modelcontextprotocol/ruby-sdk, version 1.4) is approved but not yet added; `anthropic` official Ruby SDK approved for step 9.
- Models: Position (#protection, #distance_to_stop, #open_risk, #unrealized_pnl, synced_at), Balance, Account (trading, label, sync_interval, last_sync), Trade (status, needs_review, review_reason, realized_r, legs), Setup (stats), Snapshot (drawdown, index), SchwabToken.status, SystemSettings (shadow_mode, manual_halt, sync_paused_reason), SyncRun, ToolCall (agent_run_id nullable, transport mcp|scheduled, tool_name, arguments jsonb, duration_ms, error), Dashboard read model (banner, rows, open_risk, excluded_by_reason, day_change, staleness), Schwab::Client (quotes returning pages, price_history) with Schwab.client(wait: false) for web callers and Schwab::Quote.batch / Schwab::PriceHistory mappers, Rails.cache (Solid Cache in production).
- Credentials: `mcp.bearer_token` in production credentials (a 64-char random string the user generated).
- Auth: magic-link login for humans; MCP will use the bearer only.

### Planned step 8 design
- `app/models/agent/tools/*`: one class per tool with `name`, `description`, `input_schema`, `call(**args)`, and permission metadata `read_only`, `interactive_allowed`, `scheduled_allowed`. `Agent::Tools.registry` enumerates them; `Agent::Tools.for(:mcp)` and `.for(:scheduled)` filter by metadata, enforced in one place.
- Tools return plain hashes (JSON-serializable) with every number carrying its as-of time and a `stale` flag from the same staleness rule the dashboard uses; account hashes never appear; symbols appear alongside CUSIP.
- `POST /mcp` via the `mcp` gem's Streamable HTTP transport mounted in Rails (a controller action delegating to `MCP::Server#handle_json`), bearer compared with secure_compare, 401 rendering a plain "MCP auth failed" page (Playwright target), CSRF skipped for that route, JSON only.
- Every tool call writes a ToolCall row (transport mcp, arguments, duration, error); errors are returned as MCP tool errors, never raised to the transport; Schwab failures degrade to cached values with `stale: true` or an explicit unavailable result.
- get_quotes caches per symbol for 2 minutes in Rails.cache; get_price_history for 5 minutes; both use the no-wait client so a web request never sleeps on a retry.
- get_account_health returns token status and age, sync status per feed, pause reason, shadow mode, halt, equity, settled/unsettled cash, drawdown from the latest snapshot, unprotected count and reasons.
- Rate limiting of the endpoint itself (Rack::Attack is not in the gem list; consider Rails 8's built-in rate_limit on the controller).

## Instructions
You are providing an independent review. Be critical and thorough.
- Check the plan against the MCP specification as of 2026: Streamable HTTP transport requirements (session ids, GET for SSE, DELETE, protocol version header, initialize handshake, tools/list and tools/call shapes, structured content, error semantics), and what the `mcp` Ruby gem 1.x actually provides in Rails (what the controller must do versus what the gem handles)
- Check the auth story: what the Claude app's custom connector sends and expects (bearer header availability, OAuth discovery endpoints it may probe such as /.well-known/oauth-authorization-server and /.well-known/oauth-protected-resource, dynamic client registration), and what the minimal OAuth fallback must implement to work with the Claude app; recommend whether to ship bearer-only first
- Check each tool's input schema and output for what the agent actually needs (PRD §5.7 briefs): symbols versus CUSIP, date ranges, pagination or limits on get_journal, what get_portfolio includes for unprotected positions, how staleness is represented
- Check failure behavior: token unusable, Schwab down, cache miss, an unknown symbol, a rate limit, a tool exception, request size, concurrent calls
- Check security: bearer comparison, no account hashes or plaintext numbers in any output, the endpoint being unauthenticated apart from the bearer, logging (never log tool arguments containing symbols? decide), rate limiting, whether the 401 page should exist at all
- Flag what step 9 (scheduled runtime with the Anthropic Messages API) needs from the registry now so nothing is rebuilt
- Be direct and opinionated; do not hedge; order by severity

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
