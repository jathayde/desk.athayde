# Phase 1 Plan: Investment Copilot (read-only)

Source of truth: `docs/artifacts/investment-copilot-prd.md` (v9). Screen states from `docs/artifacts/investment-copilot-ui-flows.md` and the wireframes. This plan covers only PRD §6 Phase 1 as scoped in the kickoff brief. Revision 2 incorporates the counselors PRD review (codex-5.5-high, claude-fable; outputs in `agents/counselors/1788296923-*`).

Sections: decisions, migrations, jobs, tool surface, journal builder, stops and open risk, snapshots, UI, testing, deploy, build order, deferred items, Schwab assumptions, working method.

---

## 0. Decisions (resolved 2026-09-01)

1. **Secrets in Rails credentials**, production-only file (`config/credentials/production.yml.enc`), keys `schwab.app_key`, `schwab.app_secret`, `mcp.bearer_token`, `anthropic.api_key`, `resend.api_key`, plus Active Record Encryption keys. `SCHWAB_CALLBACK_URL` and `MEMORY_REPO_PATH` stay in dokku ENV (not secret). The dokku `SCHWAB_APP_KEY`/`SCHWAB_APP_SECRET` vars get unset once the credentials file is on the server. Rotating the MCP token is an edit to the credentials file plus a deploy.
2. **Gems beyond defaults:** `rspec-rails`, `factory_bot_rails`, `vcr`, `webmock`, `bundler-audit`, `mcp` (official Ruby SDK), `anthropic` (official Ruby SDK). No claude-on-rails.
3. **Web login is passwordless magic link**, built on the Rails 8 auth generator with `generates_token_for :magic_link` (15 min, single use). Users are seeded, not self-registered: john@athayde.com and whitney@athayde.com only. No gem. Because a second person can log in, `audit_events.user_id` exists from day one so Phase 2 approvals are attributable. Fallback when email is down: `bin/rails login:link[email]` prints a magic link to the console.
4. **Email via Resend over SMTP**, no gem; API key in credentials. Production login and re-auth depend on it, so Resend DNS is a prerequisite for the first production deploy.
5. **`evaluate_hypothetical_order` omitted** from Phase 1. `get_risk_rules` ships and returns the (empty) `risk_rules` rows.
6. **§5.12 allocation tables deferred** to Phase 2.5.
7. **Off-hours cadence** for orders/transactions sync: hourly.
8. **MCP auth (open verification, not blocking):** the Claude app's custom-connector UI exposes static bearer headers only to orgs in a beta. John checks Settings → Connectors → Add custom connector for a "headers" option before step 8. If absent, the fallback is a minimal OAuth 2.1 authorization-code + PKCE endpoint on the app that issues the same bearer after magic-link login. `McpAuth` verifies the bearer either way, so the tool layer is unaffected.

---

## 1. Migrations (in creation order)

All money columns `decimal(18,4)`, quantities `decimal(18,6)` (fractional shares unverified, PRD §5.12). All timestamps `timestamptz`. No table stores a bare ticker as a key; instrument references are `instrument_id`.

| # | Table | Key columns | Phase 1 populated? |
|---|---|---|---|
| 1 | `users`, `sessions` | Rails 8 auth generator, password column removed; `email_address` unique. Magic-link tokens via `generates_token_for`, no table. | yes (two seeded users) |
| 2 | `schwab_tokens` | `access_token` (encrypted), `refresh_token` (encrypted), `access_expires_at`, `refresh_expires_at` (= `issued_at` + 7 days, never moved by access refreshes), `issued_at`, `last_refreshed_at`, `last_refresh_error`, `scope` | yes |
| 3 | `accounts` | `schwab_hash` (Schwab's opaque hashValue, unique), `account_type` enum (taxable/ira, nullable: set by the operator since Schwab only reports CASH or MARGIN), `trading_enabled` bool, `nickname`, `last_synced_at`, `raw` jsonb. A plaintext account number is never a column. | yes |
| 4 | `instruments` | `cusip` (nullable, unique where present), `schwab_instrument_id` (nullable, unique where present), `symbol`, `symbol_history` jsonb `[{symbol, until}]` (UTC), `asset_type`, `leveraged` bool default false, `description`, `predecessor_instrument_id` (self FK, set on CUSIP succession: reverse split, merger, spin-off). Identity resolution order: CUSIP, then Schwab instrument id, then symbol+asset_type as last resort with a `needs_review` audit. | yes |
| 5 | `positions` | `account_id`, `instrument_id`, `quantity`, `average_price`, `cost_basis`, `market_value`, `last_price`, `working_stop_order_id` (FK orders, nullable), `synced_at`, `raw` jsonb. Unique on (account, instrument). Rows absent from the broker response are deleted on sync. | yes |
| 6 | `balances` | Time series: `account_id`, `as_of`, `equity`, `cash_available_for_trading`, `unsettled_cash`, `settled_cash` (derived; mapping unverified), `buying_power`, `raw` jsonb. Current balance = latest row per account. | yes |
| 7 | `orders` | `account_id`, `instrument_id`, `broker_order_id` (unique per account), `status` enum incl. Phase 2 states, `side`, `quantity`, `filled_quantity`, `order_type`, `limit_price`, `stop_price`, `duration`, `session`, `tax_lot_method`, `placed_via` enum (schwab_direct/app), `parent_order_id` (self FK, bracket child), `replaces_order_id` (self FK, cancel/replace chain), `order_proposal_id` (nullable), `entered_at`, `closed_at`, `raw` jsonb | yes (sync only) |
| 8 | `order_proposals` | `account_id`, `instrument_id`, `kind` enum (entry, exit, stop_adjustment), `target_order_id` (nullable, for stop adjustments), `origin` enum (agent/human), `user_id` (nullable), `status` enum (proposed, validated, rejected, approved, submitted, submission_unknown, filled, cancelled), `side`, `quantity`, `order_type`, `limit_price`, `stop_price` (the order's own trigger), `planned_stop` (the protective stop that becomes the bracket child), `target_price`, `duration`, `session`, `tax_lot_method`, `thesis`, `setup_id`, `guardrail_results` jsonb (records `{rule_id, version}` pairs), `acknowledged_warnings` jsonb, `expires_at`, `override_reason`, `reject_reason`, `approved_at`, `submitted_at` | no |
| 9 | `submission_attempts` | `order_proposal_id`, `attempted_at`, `payload` jsonb, `response` jsonb, `outcome` enum (submitted, unknown, failed, reconciled), `reconciled_order_id` (nullable) | no |
| 10 | `activities` (the PRD's `transactions`; renamed because `transaction` is reserved by Active Record) | One row per Schwab activity. `account_id`, `instrument_id` (nullable for cash-only), `order_id` (FK, nullable), `broker_order_id` (nullable), `broker_activity_id` (unique per account), `kind` enum (fill, dividend, interest, fee, deposit, withdrawal, corporate_action, other), `sub_type` string (raw Schwab type), `side`, `quantity`, `price`, `commission`, `fees` (summed from the activity's fee transfer items), `net_amount`, `trade_date`, `settlement_date`, `executed_at`, `raw` jsonb, `journaled_at` | yes |
| 11 | `setups` | `name` (unique), `definition`, `active` bool, `win_rate`, `avg_r`, `expectancy`, `sample_size`, `stats_computed_at`. Stats are stored here and recomputed by `Journal::RecomputeSetupStatsJob` whenever a trade closes; `get_setup_stats` reads them. | table yes, rows via seed |
| 12 | `trades` | `account_id`, `instrument_id`, `setup_id` (nullable), `order_proposal_id` (nullable), `status` enum (open, closed) only, with a partial unique index allowing one open trade per account and instrument, `needs_review` bool (orphan or bootstrapped, missing setup/stop), `bootstrapped` bool (created from an existing position, entry history unavailable), `opened_at` (nullable when bootstrapped), `closed_at`, `avg_entry`, `avg_exit`, `peak_quantity`, `planned_stop`, `planned_target`, `initial_risk`, `realized_pnl`, `realized_r`, `thesis`, `post_mortem`, `followed_setup` (nullable bool), `journal_completed_at` | yes |
| 13 | `trade_legs` | `trade_id`, `activity_id` (unique where present, nil on synthetic bootstrap legs), `kind` enum (entry, exit, adjustment, income), `quantity`, `price`, `ratio` (splits), `cash_amount`, `executed_at`, `note` | yes |
| 14 | `risk_rules` | `rule_type`, `params` jsonb, `active`, `version`, `setup_id` (nullable), `superseded_by_id` | no |
| 15 | `snapshots` | `account_id`, `as_of` date (unique per account), `equity`, `net_flows` (day), `daily_return` (net of flows), `index_value` (chain-linked, starts at 1.0), `high_water_index`, `drawdown` (fraction), `open_risk_amount`, `open_risk_ratio` (fraction of equity), `unprotected_count`. Fully rebuildable from `balances` + `transactions`. | yes |
| 16 | `audit_events` | `kind` string, `actor` enum (human/system/agent), `user_id` (nullable), `subject` polymorphic (nullable), `data` jsonb, `reason`, `created_at` only. Postgres triggers reject UPDATE, DELETE, and TRUNCATE; `kind` is validated against `AuditEvent::KINDS`. Reserved for the PRD's "logged" list; not telemetry. | yes |
| 17 | `market_days` | `date` (unique), `trading` bool, `session_opens_at` (pre-market), `regular_opens_at`, `regular_closes_at`, `session_closes_at` (post-market), `raw` jsonb, `fetched_at`, `source` enum (schwab, fallback) | yes |
| 18 | `sync_runs` | `feed` enum (accounts, positions, balances, orders, transactions, market_hours, memory_repo, snapshots), `status` (running, succeeded, partial, failed, skipped_token), `started_at`, `finished_at`, `error`, `records_touched`, `unmapped_values` jsonb, `window_from`, `window_to` | yes |
| 19 | `agent_runs` | `kind` enum (morning_brief, eod, sunday_review), `status`, `degraded` bool (ran with expired token / stale data), `started_at`, `finished_at`, `tool_turns`, `input_tokens`, `output_tokens`, `estimated_cost`, `output_markdown`, `error`, `model` | yes |
| 20 | `tool_calls` | `agent_run_id` (nullable), `transport` enum (mcp, scheduled), `tool_name`, `arguments` jsonb, `duration_ms`, `error`, `created_at`. This is where MCP and runtime tool telemetry goes, not `audit_events`. | yes |
| 21 | `system_settings` | Singleton row (check constraint `id = 1`): `shadow_mode` bool default true, `manual_halt` bool default false, `manual_halt_reason`, `manual_halt_at`, `sync_paused_reason` (set while token expired) | yes |

Solid Queue / Cache / Cable schemas already generated. Every datetime column is `timestamptz` (adapter default set in an initializer). Schema format is `structure.sql` for the audit triggers; the dump pins Postgres 17 settings, so dokku runs the postgres:17 image. Active Record Encryption: production keys live in `config/credentials/production.yml.enc`; development and test share `config/credentials.yml.enc` (dev keys) with fixed test keys in `config/environments/test.rb`.

Phase 2 columns present now so `orders`/`order_proposals` never need a shape change: `parent_order_id`, `replaces_order_id`, `order_proposal_id`, `submission_unknown` state, `submission_attempts`, `guardrail_results`, `risk_rule_version`, `acknowledged_warnings`, `kind`/`target_order_id` for stop adjustments.

---

## 2. Jobs (Solid Queue, `config/recurring.yml`, all times America/New_York)

**Token gating.** Only `Sync::TickJob` and the agent jobs are scheduled; everything else is enqueued by them. When the refresh token is expired the tick job writes one `sync_runs` `skipped_token` row per hour, sets `system_settings.sync_paused_reason`, audits `sync_paused_token_expired` once per episode, and enqueues nothing. No self-re-enqueue, so the queue cannot grow. The re-auth callback clears the pause and enqueues `Sync::CatchUpJob`, which runs all feeds with windows widened to cover the gap (capped at the 60-day transactions limit). Agent jobs run degraded rather than wait: `degraded: true`, the prompt states the token is expired and every number carries its as-of time, and the email subject is prefixed accordingly. Snapshots are not written for days without a fresh balance.

| Job | Schedule | Does |
|---|---|---|
| `Schwab::RefreshAccessTokenJob` | every 25 min | POST refresh grant; update `schwab_tokens` (`refresh_expires_at` untouched); on failure audit `token_refresh_failed`; no-op when refresh token expired |
| `Schwab::TokenHealthJob` | daily 08:00 + 20:00 | Nag when `refresh_expires_at` < now + 24h. Escalation rule: on Monday and Tuesday, email if `refresh_expires_at` is before the coming Sunday 18:00 email plus 12h buffer (Sunday re-auth was missed). Audit each nag. |
| `Sync::TickJob` | every 5 min | Sole scheduled sync entry point. Refreshes `market_days` if today or the next 7 days are missing (one call per date). Due checks compare against last *started* time with 1-minute slack. Enqueues: positions+balances (15 min inside the full session window pre-market through post-market, 60 min otherwise); orders+transactions (5 min inside the session, 60 min otherwise); `Snapshots::DailyJob` once per market day after `regular_closes_at` + 20 min and after a successful positions sync since close. |
| `Sync::AccountsJob` | daily 06:05, after every re-auth | `/accounts/accountNumbers` then `/accounts`; upsert by `schwab_hash` |
| `Sync::PositionsJob` | via tick | `/accounts/{hash}?fields=positions`; resolve instruments, upsert positions, delete positions absent from the response, append a `balances` row; then `Journal::BootstrapJob` for trading-enabled accounts |
| `Sync::OrdersJob` | via tick | Window: `fromEnteredTime` = max(last success − 1 day, now − 60 days); plus a daily pull with `status=WORKING` so GTC orders older than the window stay tracked (both unverified). Upsert; flatten nested `childOrderStrategies` and `replacingOrderCollection` setting `parent_order_id`/`replaces_order_id`; re-fetch known working stops older than the window by id; set `placed_via: schwab_direct` when no proposal matches; update `positions.working_stop_order_id` (see §5) |
| `Sync::ActivitiesJob` | via tick | Overlapping cursor: from = last success − 3 days, capped at 60 days back. Upsert by `broker_activity_id`, link `order_id` via the activity's orderId, classify `kind`; then `Journal::LinkFillsJob` |
| `Sync::CatchUpJob` | after re-auth | Accounts, positions, orders, transactions with widened windows |
| `Journal::BootstrapJob` | after positions sync | See §4 |
| `Journal::LinkFillsJob` | after activities sync | See §4 |
| `Journal::RecomputeSetupStatsJob` | after any trade closes | Rolling stats onto `setups` |
| `Snapshots::DailyJob` | via tick | See §6 |
| `Jobs::FailureDigestJob` | daily 17:00 | One email listing failed `sync_runs`, `agent_runs`, and Solid Queue failed executions since the last digest, grouped by kind |
| `Memory::PullRepoJob` | every 30 min | `git -C $MEMORY_REPO_PATH pull --ff-only`; record `sync_runs` |
| `Agent::MorningBriefJob` | 07:00 market days | See §3 |
| `Agent::EndOfDayJob` | 16:30 market days | See §3 |
| `Agent::SundayReviewJob` | Sunday 18:00 | Phase 1 stub, no API call: re-auth link, token age, sync health, job failures, setup stats table |

**Schwab client:** built to `docs/schwab-api-contract.md`. Net::HTTP; plaintext account numbers scrubbed inside the client before any body is returned; logs carry path templates (`/accounts/{hash}/orders`), never hashes, bodies, or headers; one time helper for the three input and three output formats; `BigDecimal` for every money and quantity value; a shared Solid Cache rate budget of 100 requests/minute across Puma and the worker; retries on 429, 5xx, and transport errors for GETs and the refresh grant only (1, 4, 16 s with jitter, `Retry-After` capped at 60 s), never on 4xx; one refresh-and-retry on a 401. Error classes: `AuthError`, `ReauthRequired`, `RateLimited`, `ServerError`, `RequestError`, `TransportError`, `UnknownOutcome` (non-idempotent calls only, chosen by HTTP method), `MappingError`. Interface adds `order(hash, order_id)` so working stops older than the lookback are re-fetched by id, and `instrument(symbol_or_cusip)` for identity fallback. Mappers return `Data` structs with a scrubbed `raw` member; jobs never see a Schwab field name. `Schwab::FakeClient` sits below the mappers and returns raw-shaped hashes with a scriptable per-call queue. Sync runs can finish `partial` with an `unmapped_values` count when individual records are quarantined.

---

## 3. Tool surface (one registry, two transports)

`app/models/agent/tools/*` each defines `name`, `description`, `input_schema`, `call(**args)`, and permission metadata: `read_only`, `interactive_allowed`, `scheduled_allowed`. The MCP server registers tools where `interactive_allowed`; the scheduled runtime passes only tools where `scheduled_allowed && read_only`, enforced in one place so a Phase 2 write tool cannot reach an unattended run by omission. Phase 1 tools:

| Tool | Returns |
|---|---|
| `get_portfolio` | Positions with last price, unrealized P&L, working stop, distance to stop, per-position open risk, `unprotected` flag, synced_at per row |
| `get_account_health` | Equity, settled/unsettled cash, drawdown from HWM (index-based), unprotected count, token status and age, last sync per feed, shadow mode, halt state, sync pause reason |
| `get_quotes(symbols)` | Schwab `/marketdata/v1/quotes`, cached 2 min in Solid Cache, each quote stamped with fetched_at; when the token is expired returns the cached value with `stale: true` or an explicit unavailable error |
| `get_price_history(symbol, range)` | Schwab `/marketdata/v1/pricehistory`, cached 5 min |
| `get_journal(filters)` | Trades with legs; filters: status, needs_review, setup, instrument, date range, missing_post_mortem |
| `get_setup_stats` | Stored stats from `setups` |
| `get_risk_rules` | Active `risk_rules` rows (empty in Phase 1) |

Every call writes a `tool_calls` row. Nothing in this section writes to `audit_events`.

**MCP server:** `POST /mcp` (Streamable HTTP, JSON-RPC 2.0). `McpAuth` extracts a bearer from `Authorization` and compares with `ActiveSupport::SecurityUtils.secure_compare`; 401 renders a plain "MCP auth failed" page (Playwright target). See decision 0.8 for the OAuth fallback.

**Scheduled runtime:** `Agent::Run` wraps one Messages API conversation: system prompt = memory repo markdown files + setup stats + token health + as-of timestamps; tools = scheduled-allowed registry; hard cap `MAX_TOOL_TURNS = 12`; result stored in `agent_runs` and emailed via `BriefMailer`. Prompts live in `app/models/agent/prompts/*.md.erb`. The morning-brief prompt states that earnings and economic-calendar data are unavailable in Phase 1 and must not be inferred. Morning brief and EOD are real; Sunday review stub does not call the API.

---

## 4. Journal builder (zero-to-zero, trading-enabled accounts only)

IRA and other read-only accounts sync positions and transactions (for Phase 2 wash-sale checks) but never create trades.

**Bootstrap** (`Journal::BootstrapJob`, after every positions sync): for each position in a trading-enabled account with no open trade, create a trade with `bootstrapped: true, needs_review: true, status: open`, `avg_entry` = broker average price, `peak_quantity` = quantity, `opened_at` nil, one synthetic `entry` leg with no transaction. This covers day-one holdings and any position whose entry fills are beyond the 60-day transactions window.

**Link fills** (`Journal::LinkFillsJob`), per account and instrument, transactions in `executed_at` order, skipping already-journaled rows:
- Buy fill, no open trade: open a trade. If `transactions.order_id` → `orders.order_proposal_id` resolves, copy setup, thesis, planned stop, target; else `needs_review: true`.
- Sell fill, no open trade: bootstrap a trade first (as above, quantity from the fill), then apply the exit. `needs_review: true`.
- Every fill is a leg (`entry` or `exit`). Running quantity, `avg_entry`, `avg_exit`, `peak_quantity` recomputed.
- Running quantity reaches zero: `status: closed`, `closed_at`, `realized_pnl` = exits − entries − commissions − fees + income legs.
- `initial_risk` = quantity of the first entry leg × (its price − `planned_stop`), fixed at that moment. `realized_r` = `realized_pnl` / `initial_risk`, nil when no planned stop.
- Cash dividend or interest with a CUSIP matching an open trade: `income` leg, feeds `realized_pnl`, does not touch basis.
- Split or reverse split: `adjustment` leg with `ratio`, zero cash; `quantity`, `avg_entry`, `planned_stop`, `planned_target` scaled by the ratio.
- Return of capital / basis change: `adjustment` leg with `cash_amount`, adjusts `avg_entry`.
- CUSIP succession (merger, spin-off, reverse split issuing a new CUSIP): when an `out` on instrument A and an `in` on instrument B arrive as one corporate-action activity or within the same activity group, set `instruments.predecessor_instrument_id` on B and move the open trade to B with an `adjustment` leg. Unmatched halves fall back to normal exit/entry handling with `needs_review`.
- Symbol change on a known CUSIP: update `instruments.symbol`, append `symbol_history`, trades untouched.
- Idempotent via the unique index on `trade_legs.activity_id`, and one open trade per account and instrument via a partial unique index.

**Review path** (Flow 4 plus the Monarch-style orphan review from the flows doc): trades with `needs_review` show a "N trades need review" banner on the dashboard. The review form takes setup, planned stop, and thesis; saving clears `needs_review`, computes `initial_risk`, and audits `trade_reviewed`. The post-mortem form (one line plus followed/improvised) is separate and available on any closed trade.

---

## 5. Stops and open risk in Phase 1

No stop is not zero risk. `Sync::OrdersJob` identifies, per position, a working broker-side stop: a sell order on the same instrument with `order_type` STOP or STOP_LIMIT and status in the working set (WORKING, ACCEPTED, QUEUED, PENDING_ACTIVATION; enum unverified), following `replaces_order_id` chains. It sets `positions.working_stop_order_id` or clears it.

- Protected position (a working stop order with a readable price): distance to stop = (last − stop) / last, signed; open risk = max(quantity × (last − stop), 0).
- Unprotected position (no stop, a stop that is no longer working, or a trailing stop with no price): `unprotected` flag, distance and risk shown as unknown, never zero.
- Portfolio open risk = sum over protected positions, and the dashboard and `get_account_health` state how many positions are excluded as unprotected.

---

## 6. Snapshots (per account, chain-linked)

For each trading-enabled account and market day after close:
- `equity` = latest balance equity for the day.
- `net_flows` = sum of deposit and withdrawal transactions with `trade_date` on the day (deposits positive).
- `daily_return` = (equity − net_flows − prior equity) / prior equity. First snapshot has return 0 and index 1.0.
- `index_value` = prior index × (1 + daily_return); `high_water_index` = max to date; `drawdown_pct` = 1 − index / high_water_index.
- `open_risk_amount`, `open_risk_pct`, `unprotected_count` from §5 at snapshot time.
- Rebuildable: `Snapshots::RebuildJob(account, from:)` recomputes forward from any date, and `Sync::ActivitiesJob` enqueues a rebuild from the earliest newly seen deposit/withdrawal date, so a flow that lands a day late corrects the series.

---

## 7. UI (Hotwire, mobile-responsive, no JS routers, no hover-dependent modals)

| Screen | Route | Phase 1 content |
|---|---|---|
| Dashboard | `/` | Banner (healthy / expiring / expired / halted), equity + day change, open risk with unprotected count, settled/unsettled cash, positions list with distance-to-stop as the primary number and inline `unprotected` where applicable, "N trades need review" callout, pending proposals count (0), staleness stamps on every number, empty state before first sync |
| Trade review | `/trades/:id/review` | Setup, planned stop, thesis for `needs_review` trades; "N more to review" progression |
| Trade detail / post-mortem | `/trades`, `/trades/:id` | List and detail; Flow 4 quick entry (one line + followed/improvised) |
| System health | `/system` | Token age vs 7d with next Sunday marked, last sync per feed, sync pause reason, job failures (7d), API spend (month, from `agent_runs`), shadow mode indicator, manual halt toggle with reason (audited) |
| Re-auth | `/schwab/authorize` → Schwab → `/schwab/callback` | Requires login; success page with new expiry and catch-up sync enqueued; failure page with error and retry |
| Login | `/session/new` → email → `/session/magic/:token` | Passwordless; unknown emails get the same "check your inbox" response |

**App mark:** the Athayde (Ataíde) family arms, azure, four bends argent running top-left to bottom-right, from the Portuguese Ataíde family (https://en.wikipedia.org/wiki/Ata%C3%ADde_family); the crest animal is a lion, reserved for later use. It sits top-left of the shell on every screen and serves as favicon and PWA icon. Vector at `app/assets/images/brand/crest.svg`, drawn from the athayde.com reference PNG kept in `docs/artifacts/brand/`.

Banner precedence: halted > expired > expiring > healthy. Halted in Phase 1 comes only from `system_settings.manual_halt`.

---

## 8. Testing

- **RSpec**, in the kickoff's priority order: token lifecycle with `travel_to` (25-minute refresh, 7-day expiry unaffected by refreshes, pause and catch-up, Mon/Tue escalation rule); sync jobs with fixture payloads (positions incl. removal, orders incl. cancel/replace and working stops, transactions incl. cash dividend, split, return of capital, CUSIP succession, fee items); journal linking (scale-in/out, orphan fill, sell-first legacy holding, bootstrap, ticker change on same CUSIP, R math); snapshot math (flows, late-landing deposit rebuild); MCP tool contracts (auth, each tool's schema and output, permission metadata excludes non-scheduled tools); scheduled runtime with a stubbed Messages API (turn cap, degraded mode).
- **VCR cassettes** in `spec/cassettes`, recorded against Schwab only once the app is Ready For Use, with a scrubber that replaces bearer tokens, refresh tokens, and account hash values before write. Until then, cassettes are hand-built from community-client response shapes and marked `# SCHWAB_SHAPE_UNVERIFIED`.
- **`Schwab::FakeClient`** implements the same interface as `Schwab::Client`, returns canned payloads, selected by `config.x.schwab.adapter`. Used by dev seeds and Playwright.
- **Playwright** (`e2e/`, `@playwright/test` via npm, the only Node dependency): dashboard in four banner states via a test-env-only `/playwright/scenarios/:name` reseed route, MCP 401 page, re-auth success and failure (FakeClient scripted), trade review flow.
- **`bin/ci`**: Rails 8.1 `ActiveSupport::ContinuousIntegration` with steps in `config/ci.rb`, the pattern borrowed from Patchvault. Kickoff order: rubocop → rspec → brakeman (strict, warnings fail) → `bin/importmap audit` → `bundle exec bundle-audit check --update` → Playwright (`bin/playwright`, which boots a test-env server with the FakeClient, runs `npx playwright test`, and tears down). Fails on the first red step.

---

## 9. Deploy

- `Procfile`: `web: bundle exec puma -C config/puma.rb`, `worker: bin/jobs`, `release: bin/rails db:prepare`. Postgres service on the `postgres:17` image (structure.sql uses PG17 settings).
- `app.json` for the release phase.
- `bin/dokku-setup`: documents postgres plugin, letsencrypt, config vars (`RAILS_MASTER_KEY`, `SCHWAB_CALLBACK_URL`, `MEMORY_REPO_PATH`), storage mount for the memory repo, `ps:scale worker=1`, and the daily offsite DB dump from PRD §5.9 (postgres plugin backup to object storage on a cron).
- App time zone `Eastern Time (US & Canada)`; Solid Queue recurring schedules use the same.

---

## 10. Build order (green `bin/ci` at each step)

1. Tooling: RSpec, rubocop config, brakeman, bundler-audit, `bin/ci` (without Playwright), authentication generator adapted to magic link, AR encryption keys, credentials layout, crest in the layout.
2. Migrations 1–21, models with validations/enums, `AuditEvent` append-only trigger, `SystemSettings` singleton.
3. Schwab adapter: `Schwab::Client` (OAuth, accounts, positions, orders, transactions, market hours, quotes, price history) with retry/backoff/limiter, `Schwab::FakeClient`, response mappers, `docs/verify-on-approval.md` started from §12.
4. OAuth controller + token model + refresh job + token health job + re-auth pages + pause/catch-up + audit events.
5. Sync jobs, market calendar, tick scheduler, `sync_runs`, working-stop detection.
6. Journal builder (bootstrap, link, review path) + setup stats + snapshots.
7. Dashboard, system health, trade screens; Playwright added to `bin/ci`.
8. MCP server + tool registry with permission metadata (after decision 0.8 is verified).
9. Scheduled runtime + mailers (briefs, nags, failure digest) + memory repo pull.
10. Seeds for dev via FakeClient; `Procfile`, `app.json`, `bin/dokku-setup`; DHH-skill review pass.

---

## 11. Explicitly not built in Phase 1

Guardrail engine, order proposals (tables only), approval UI, submission, brackets, reconciliation job, allocation module, FMP, earnings/econ calendar, watchlist screen (watchlist.md in the memory repo is read as text), push notifications, iOS shell.

---

## 12. Schwab assumptions to verify on approval

Maintained in `docs/verify-on-approval.md` (30 items as of the step 3 contract review). The original seed list:

From PRD §9: exact `TaxLotMethod` enum values; order-endpoint rate limits. Added by this plan:
- `/accounts/{hash}?fields=positions` returns balances in the same payload (`currentBalances`, `initialBalances`).
- Which balance fields map to settled cash vs unsettled cash for a cash account.
- Orders endpoint supports `fromEnteredTime`/`toEnteredTime` and a `status` filter; maximum lookback window.
- Transactions endpoint: 60-day start-date limit, `activityId` uniqueness, `orderId` presence on trade activities, transfer-item structure with fee items, CUSIP presence on every instrument (cash equivalents, sweeps, options).
- Corporate-action activity shapes for splits, mergers, spin-offs, return of capital, and whether old and new CUSIPs arrive in one activity.
- Market-hours endpoint takes one date per call and returns pre/regular/post session times.
- Order status enum values for "working" stops; cancel/replace produces a new order id and marks the old one REPLACED.
- Fractional-share quantities in positions and orders.
- Refresh token expiry is 7 days from issuance and is not extended by access-token refreshes.
- Claude app custom connectors: static bearer header availability for this org (decision 0.8).

---

## 13. Working method, per phase and per build step

Each numbered step in §10 that ships a feature runs this loop:

1. **PRD review with counselors** (`counselors run`, agents `codex-5.5-high` and `claude-fable`): the relevant PRD sections plus this plan's section for the step. Findings are folded into the plan before code.
2. **Build** the feature vertically per §10.
3. **RSpec green** and reviewed for coverage against the §8 priority list, not just passing.
4. **DHH skill review pass** (`dhh-code-reviewer` agent) on the step's diff; fix what it flags.
5. **Counselors review of the build** (same two agents) on the diff; fix or explicitly decline each finding in the commit message.
6. **`bin/ci` green.** Commit.

Counselors runs are long (10 to 20 minutes) and run in the background while unrelated work continues. Whole-phase gates: the counselors PRD review before step 1 (done, revision 2 of this plan is the result), and a DHH pass plus counselors review over the full Phase 1 diff after step 10.
