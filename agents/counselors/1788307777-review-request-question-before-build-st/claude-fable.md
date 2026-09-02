Review complete. Findings below, ordered by severity, drawn from the current spec revisions, the `mcp` gem 1.4.0 source and docs, and Claude's connector documentation.

## Blocking: what breaks when the Claude app connects

**1. The controller must not call `MCP::Server#handle_json` directly.** That method returns a JSON string for requests and nil for notifications. It knows nothing about HTTP. The plan's controller would therefore return 200 with a body of `null` for `notifications/initialized`, where the spec requires 202 with no body. It would also skip the Accept-header check, GET and DELETE handling, and the `MCP-Protocol-Version` validation. Most important, the spec's current revision is 2026-07-28, which removed `initialize` and sessions and added `server/discover` and a `_meta` envelope. Gem 1.4.0 serves both eras, but only through its transport. The documented Rails pattern is:

```ruby
class McpController < ActionController::API
  def create
    server = MCP::Server.new(name: "desk", version: "1.0", tools: Agent::Mcp::TOOLS)
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      enable_json_response: true,
      serve_subscriptions_listen: false,
      allowed_hosts: Rails.application.config.hosts.map(&:to_s),
      max_request_bytes: 64.kilobytes
    )
    status, headers, body = transport.handle_request(request)
    response.headers.merge!(headers)
    render json: body.first, status: status
  end
end
```

Route it as `match "/mcp", via: %i[post get delete]` so the transport can answer GET and DELETE with 405 itself. Add a request spec asserting the body is an Array on every path, since a streaming body would break `body.first`.

**2. The gem's DNS-rebinding protection rejects your production host by default.** It validates `Host` against loopback names only and returns 403 "Invalid Host header" for anything else. The first POST from Claude to desk.athayde.com fails. Pass `allowed_hosts` as above. Request specs default to `www.example.com` and Playwright uses `127.0.0.1:3100`, so add those in test. A request without an `Origin` header passes, which is what Claude sends.

**3. Stateless mode is mandatory, not optional.** The stateful transport keeps sessions in a per-process hash. Puma runs 3 threads today and any future `WEB_CONCURRENCY` above 1 would lose sessions between workers. Nothing here needs sessions.

**4. Bearer-only is the right first ship, but the connector dialog is the thing to verify, not the header.** Claude's docs now confirm static headers exist in beta and are org-gated. In the dialog you pick Authentication "None", then add `authorization` under Request headers with the value entered as `Bearer <token>` including the scheme, because Claude sends the value verbatim. Two risks:

- After you enter the URL, Claude probes it to "detect" auth. A 401 on that probe may steer the dialog toward OAuth. If the dialog does not let you override to None, the fallback is lazy-auth style gating: let `initialize` and `tools/list` through unauthenticated and require the bearer only on `tools/call`. Keep full gating as the default and test this first.
- Header settings cannot be edited after the connector is added. Rotating the token means remove and re-add the connector.

**5. The OAuth fallback in decision 0.8 is not "a minimal endpoint".** If your org lacks the headers section, Claude requires all of the following before it will connect:

- Protected resource metadata at `/.well-known/oauth-protected-resource/mcp` with `resource` exactly `https://desk.athayde.com/mcp` and an `authorization_servers` list.
- Authorization server metadata at `/.well-known/oauth-authorization-server` with `code_challenge_methods_supported: ["S256"]`.
- A client identity: pre-registered client id entered in Advanced settings is the cheapest. Otherwise DCR or Client ID Metadata Documents.
- Exact redirect URI `https://claude.ai/api/mcp/auth_callback`, a form-urlencoded token endpoint answering in under 10 seconds, refresh-token rotation, and audience validation of the `resource` parameter.

Treat that as its own build step, not a step 8 fallback. In the interim, Claude Code supports `claude mcp add --transport http --header` and can drive the same server for verification.

**6. The 401 must be a JSON response with a `WWW-Authenticate` header, not an HTML page.** MCP clients never render HTML. Return `401`, `WWW-Authenticate: Bearer error="invalid_token"`, and a one-line JSON body. Omit `resource_metadata` in the bearer-only design or Claude will try to discover an authorization server that does not exist. Drop the Playwright target from the kickoff list. A request spec covers it. Never log the presented credential on this branch.

**7. Use `ActionController::API`.** It has no session, no CSRF, no `allow_browser`, and no `Authentication` concern to skip, so Brakeman with `--exit-on-warn` does not see a disabled-CSRF warning. `rate_limit` is available there. Check the bearer in a `before_action` before the transport sees the body.

## Design changes before build

**Tool exceptions become protocol errors unless you rescue them.** The gem turns any unexpected exception in a tool into JSON-RPC `-32603` "Internal error calling tool", which is a protocol error the model cannot recover from. The plan's promise of "errors returned as MCP tool errors" requires the registry's own `call` wrapper to rescue `StandardError`, write the `ToolCall.error`, and return an error result with actionable text. Set `exception_reporter` to log the original. Return only `Schwab::Error#message`, never `body`.

**Degrading to cached values needs a cache that outlives the freshness window.** A 2-minute `expires_in` means the entry is gone exactly when Schwab fails. Write quotes with a long expiry, store `fetched_at`, and treat age over 2 minutes as a miss that triggers a refetch. On refetch failure, return the old entry with `stale: true` and a `warning`. Same for price history at 5 minutes. Use `fetch_multi` so a partial hit only fetches the misses.

**Reserve Schwab budget for sync.** MCP quote calls share the 100/min `RateBudget` with the tick jobs. Have the tools call `RateBudget.take!(budget: 70)` so a chatty session cannot starve sync. Return `RateLimited` as a tool error carrying `retry_after`, never sleep.

**Wrap the Dashboard read model, do not re-derive.** `get_portfolio` and `get_account_health` should call `Dashboard` for rows, protection, open risk, staleness, state, and banner. That is the PRD's "read models cannot diverge" made literal. Return the `protection` enum, not a boolean, plus `stop_price`, `covered_quantity`, `distance_to_stop`, and `open_risk` nil when unknown. Include `state` so an empty result reads as `waiting_first_sync`, not an error. One caveat: `Dashboard#stale?` calls `MarketDay.session_open?`, which can hit Schwab when the day's row is missing. Compute `in_session` once per request and pass it down.

**Output shape.** Return `structured_content` and a text block with the same JSON, per the spec's compatibility rule. Rails encodes BigDecimal as a string; keep that and say so in the description. Timestamps ISO 8601 in America/New_York. Exclude every `raw` column. Add one spec that walks every tool's serialized output for the 64-hex account-hash pattern, `raw`, and `accountNumber`. `Account#label` falls back to the last four characters of the hash. Override that for tool output. Set annotations `read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false` on every Phase 1 tool. Claude uses them for its approval prompts.

**Schemas.** `additionalProperties: false` everywhere and `{type: object, additionalProperties: false}` for no-argument tools. Enable `validate_tool_call_arguments`. Specific tools:

- `get_quotes`: `symbols` array, max 50, upcased. Return Schwab's `invalid_symbols` in the result. Error only if every symbol is invalid.
- `get_price_history`: `range` as an enum mapping to period and frequency, daily or weekly only. No intraday in Phase 1. Include `previous_close`.
- `get_journal`: `limit` default 50, max 200, `offset`, `include_legs` default false. Filters by status, needs_review, setup name, symbol, opened and closed date ranges, missing_post_mortem. Claude.ai truncates results around 150,000 characters.
- `get_setup_stats`: include `stats_computed_at`, `sample_size`, and the eligibility rule in the description so the agent does not over-trust n=3.
- `get_account_health`: token status with `refresh_expires_at`, per-feed `last_success_at` and last failure, snapshot `as_of` with drawdown, halt reason and time, but never the user's email for `halted_by`.

**Logging.** Rails logs JSON body parameters, so tool arguments with symbols will appear in production logs. For a single-user app that is acceptable. Decide it explicitly and move on. The Authorization header is not logged by Rails.

**Rate limiting.** `rate_limit to: 60, within: 1.minute` on the controller, backed by Solid Cache, is enough. The real limiter is the Schwab budget above. Cap `max_request_bytes` well below the gem's 4 MiB default.

## What step 9 needs from the registry now

- **Gem-free registry.** `Agent::Tools::*` are plain objects with `name`, `description`, `input_schema`, `call`. Build the `MCP::Tool` classes once at boot from the registry via `MCP::Tool.define`. The Anthropic Messages API `tools` array is the same `{name, description, input_schema}` triple, so `Agent::Tools.definitions(:scheduled)` needs no translation.
- **One dispatch entry point.** `Agent::Tools.call(name, arguments, transport:, agent_run: nil)` does lookup, permission check, schema validation, `deep_symbolize_keys` on arguments, the `ToolCall` row, timing, and exception-to-error-result. MCP and the scheduled runtime become two thin callers. The gem hands symbol keys to tools and the Anthropic SDK may hand strings, so normalize here.
- **One serializer.** Each tool returns a hash. The runtime sends the JSON text as the `tool_result`. MCP sends the same text plus `structured_content`.
- **Enforce the permission invariant at boot.** Raise if any tool has `scheduled_allowed` without `read_only`. Map `read_only` to the MCP annotations so the metadata is written once.
- **Schema table is sufficient.** `tool_calls` already has `agent_run_id`, `transport`, `duration_ms`, and `error`. No migration needed for step 8 or 9.

Sources:
- [MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
- [MCP 2026-07-28 Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
- [MCP 2025-11-25 authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [MCP 2025-11-25 tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [Ruby SDK transports](https://ruby.sdk.modelcontextprotocol.io/server/transports/)
- [Ruby SDK configuration](https://ruby.sdk.modelcontextprotocol.io/server/configuration/)
- [Ruby SDK StreamableHTTPTransport source](https://raw.githubusercontent.com/modelcontextprotocol/ruby-sdk/main/lib/mcp/server/transports/streamable_http_transport.rb)
- [Ruby SDK changelog](https://raw.githubusercontent.com/modelcontextprotocol/ruby-sdk/main/CHANGELOG.md)
- [Claude connectors: authentication](https://claude.com/docs/connectors/building/authentication)
- [Claude connectors: building](https://claude.com/docs/connectors/building)
- [Claude connectors: custom remote MCP dialog and request headers](https://claude.com/docs/connectors/custom/remote-mcp)
- [Claude connectors: troubleshooting](https://claude.com/docs/connectors/building/troubleshooting)
- [Claude connectors: lazy authentication and the 401 shape](https://claude.com/docs/connectors/building/lazy-authentication)
- [Rails rate_limit](https://api.rubyonrails.org/classes/ActionController/RateLimiting/ClassMethods.html)
- [claude-ai-mcp issue 411](https://github.com/anthropics/claude-ai-mcp/issues/411)
