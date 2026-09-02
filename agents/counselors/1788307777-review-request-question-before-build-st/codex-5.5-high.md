**Verdict**

Step 8 will break in Claude on auth and transport unless the plan changes. The internal tool registry idea is solid. The planned Rails MCP edge is not.

**Critical Breaks**

1. **Bearer-only only works if your org has Claude `static_headers` beta.** Claude docs say fixed bearer/API-key headers are beta and only available to limited orgs; if the Request headers UI is absent, Claude cannot send your `Authorization: Bearer ...` token. Ship bearer-only only after John verifies that UI in Claude. Otherwise, build OAuth before declaring Step 8 done. Source: Claude remote MCP docs and auth matrix state request headers are beta and values are sent exactly as entered, including the `Bearer ` prefix: https://claude.com/docs/connectors/custom/remote-mcp, https://claude.com/docs/connectors/building/authentication

2. **The OAuth fallback as described is too small.** “Authorization-code + PKCE endpoint issuing the same bearer after magic-link login” is not enough for Claude. You need protected-resource metadata, authorization-server discovery, `/authorize`, `/token` accepting `application/x-www-form-urlencoded`, S256 PKCE, and either DCR, CIMD, or a pre-registered client path. Claude’s hosted redirect URI is `https://claude.ai/api/mcp/auth_callback`. A plain 401 page without `WWW-Authenticate: Bearer resource_metadata="..."` will fail discovery. Source: https://claude.com/docs/connectors/building/authentication and https://claude.com/docs/connectors/building/lazy-authentication

3. **`POST /mcp` via controller + `handle_json` is the wrong integration target.** Streamable HTTP is not “POST JSON-RPC only.” The 2025 handshake transport uses POST, optional GET for SSE, DELETE for session termination, `MCP-Session-Id`, and `MCP-Protocol-Version`; the 2026-07-28 modern transport is stateless and uses `server/discover`. The Ruby SDK 1.4 docs say `MCP::Server::Transports::StreamableHTTPTransport` is a Rack app and should be mounted directly, or `handle_request(request)` used carefully in a stateless controller. Do not hand-roll `handle_json`. Source: MCP transport spec https://modelcontextprotocol.io/specification/2025-11-25/basic/transports and Ruby SDK docs https://ruby.sdk.modelcontextprotocol.io/server/transports/

4. **A per-request controller breaks sessionful clients unless explicitly stateless.** The Ruby SDK stores legacy handshake session/SSE state in memory. If you instantiate a server/transport per request, `Mcp-Session-Id` continuity breaks. Use a mounted singleton Rack transport for `/mcp`, wrapped by auth/rate-limit middleware. If you choose controller mode, set `stateless: true` and `serve_subscriptions_listen: false`, and verify Claude accepts that path.

**Tool Contract Fixes**

Return `MCP::Tool::Response`, not plain hashes. Put the JSON object in `structured_content`/`structuredContent`, and also include a text block with serialized JSON for older clients. Define `output_schema` for every tool and enable result validation in test. MCP structured output is first-class now; plain hashes are an internal convenience, not the wire contract. Source: https://modelcontextprotocol.io/specification/2025-11-25/server/tools and https://ruby.sdk.modelcontextprotocol.io/server/tools/

Tighten schemas now:

- `get_quotes`: `symbols` array, max 100, uppercase normalization, dedupe, explicit `invalid_symbols`, quote `fetched_at`, source quote/trade times, CUSIP.
- `get_price_history`: do not accept vague `range`; accept either preset ranges or explicit `start_date`, `end_date`, `frequency`, with hard caps.
- `get_journal`: must paginate. Add `limit`, `cursor`, deterministic sort, and date bounds. Journal can grow fast.
- `get_portfolio`: include protection state, reason, covered quantity, stop order status, and excluded-open-risk reason. Do not collapse “unprotected,” “partial,” “oversized,” and “trailing unknown.”
- `get_account_health`: include both token usability and market-data availability. A usable app with an expired Schwab token is still connectable, just degraded.
- `get_risk_rules`: return `[]` plus `phase: 1`/`available: false` for guardrails, so Claude does not infer missing data.

For staleness, standardize every numeric as `{ value, as_of, stale, source }`. Use decimal strings for money/quantities to avoid float drift; use fractions for ratios and name them clearly.

**Failure Behavior**

Token unusable should not become a transport error. Tool calls should return structured unavailable/degraded results, except auth failures. If cache exists, return it with `stale: true`; if cache misses, return `isError: true` with a retryable reason.

Unknown symbols are not exceptions; Schwab returns invalid symbols inside successful quote responses. Surface them.

Rate limits need a shared budget across sync jobs and MCP calls. The no-wait client prevents sleeping in web requests, but it does not prevent Claude from causing bursts. Return `rate_limited` with `retry_after_seconds`, and log it.

Wrap all tool execution in one registry runner that records `ToolCall` in `ensure`, catches exceptions, scrubs errors, records duration, and returns MCP tool errors. Do not put telemetry in each tool.

**Security**

Do not render a friendly 401 HTML page in production. For static-header auth, a short text body is fine; for OAuth, the `WWW-Authenticate` header is mandatory. Playwright should assert status/header, not a page.

`secure_compare` must be length-safe. Check presence and byte length first, or compare digests/fixed-length values. Never log `Authorization`.

Do not return raw Schwab payloads from tools. Raw payloads can contain broker fields you did not intend to expose. Also do not expose account hash values; use labels like `trading`, `ira_read_only`, or internal role names.

Logging symbols in `tool_calls.arguments` is acceptable for this app; symbols are not credentials and are useful telemetry. Scrub free-text fields once Phase 2 write tools exist.

Add endpoint rate limiting by token/IP, request size limits, JSON-only enforcement, Host/Origin allow-listing, and no wildcard CORS.

**Step 9 Requirements**

The registry needs a transport-neutral definition now:

- `name`, `description`, `input_schema`, `output_schema`
- `read_only`, `interactive_allowed`, `scheduled_allowed`
- `mcp_annotations` (`read_only_hint`, `destructive_hint: false`, `open_world_hint`)
- `anthropic_tool_definition`
- one `call_tool(name, args, transport:, agent_run: nil)` wrapper for permission checks, telemetry, timeout, and error normalization

Step 9 should not rebuild the tools. It should reuse the same schemas and call wrapper, with scheduled filtering and a hard turn cap. Also decide whether scheduled runtime disables parallel tool use or makes every tool reentrant.

**Recommendation**

Proceed with Step 8 only after changing the plan to mount `StreamableHTTPTransport` as Rack middleware and after verifying Claude request headers. If headers are unavailable, do not ship bearer-only. Build the OAuth discovery/PKCE path first, because that is the supported Claude connector path.
