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
| 2 | `schwab_tokens` | `access_token` (encrypted), `refresh_token` (encrypted), `access_expires_at`, `refresh_expires_at` (= `issued_at` + 168 hours, never moved by access refreshes), `issued_at`, `last_refreshed_at`, `last_refresh_error`, `revoked_at`, `scope` | yes |
| 3 | `accounts` | `schwab_hash` (Schwab's opaque hashValue, unique), `account_type` enum (taxable/ira, nullable: set by the operator since Schwab only reports CASH or MARGIN), `trading_enabled` bool, `nickname`, `last_synced_at`, `raw` jsonb. A plaintext account number is never a column. | yes |
| 4 | `instruments` | `cusip` (nullable, unique where present), `schwab_instrument_id` (nullable, unique where present), `symbol`, `symbol_history` jsonb `[{symbol, until}]` (UTC), `asset_type`, `leveraged` bool default false, `description`, `predecessor_instrument_id` (self FK, set on CUSIP succession: reverse split, merger, spin-off). Identity resolution order: CUSIP, then Schwab instrument id, then symbol+asset_type as last resort with a `needs_review` audit. | yes |
| 5 | `positions` | `account_id`, `instrument_id`, `quantity`, `average_price`, `cost_basis`, `market_value`, `last_price`, `working_stop_order_id` (FK orders, nullable), `synced_at`, `raw` jsonb. Unique on (account, instrument). Rows absent from the broker response are deleted on sync. | yes |
| 6 | `balances` | Time series: `account_id`, `as_of`, `equity`, `cash_available_for_trading`, `unsettled_cash`, `settled_cash` (derived; mapping unverified), `buying_power`, `raw` jsonb. Current balance = latest row per account. | yes |
| 7 | `orders` | `account_id`, `instrument_id`, `broker_order_id` (unique per account), `status` enum incl. Phase 2 states, `side`, `quantity`, `filled_quantity`, `order_type`, `limit_price`, `stop_price`, `remaining_quantity`, `strategy_type` (SINGLE/TRIGGER/OCO, reconciliation needs it), `duration`, `session`, `tax_lot_method`, `placed_via` enum (schwab_direct/app), `parent_order_id` (self FK, bracket child), `replaces_order_id` (self FK, cancel/replace chain), `order_proposal_id` (nullable), `entered_at`, `closed_at`, `raw` jsonb. `instrument_id` is nullable for container strategies with no legs. Index on (account, instrument, entered_at) for Phase 2 reconciliation. An upsert never nulls a lineage or proposal column that already has a value | yes (sync only) |
| 8 | `order_proposals` | `account_id`, `instrument_id`, `kind` enum (entry, exit, stop_adjustment), `target_order_id` (nullable, for stop adjustments), `origin` enum (agent/human), `user_id` (nullable), `status` enum (proposed, validated, rejected, approved, submitted, submission_unknown, filled, cancelled), `side`, `quantity`, `order_type`, `limit_price`, `stop_price` (the order's own trigger), `planned_stop` (the protective stop that becomes the bracket child), `target_price`, `duration`, `session`, `tax_lot_method`, `thesis`, `setup_id`, `guardrail_results` jsonb (records `{rule_id, version}` pairs), `acknowledged_warnings` jsonb, `expires_at`, `override_reason`, `reject_reason`, `approved_at`, `submitted_at` | no |
| 9 | `submission_attempts` | `order_proposal_id`, `attempted_at`, `payload` jsonb, `response` jsonb, `outcome` enum (submitted, unknown, failed, reconciled), `reconciled_order_id` (nullable) | no |
| 10 | `activities` (the PRD's `transactions`; renamed because `transaction` is reserved by Active Record) | One row per Schwab activity. `account_id`, `instrument_id` (nullable for cash-only), `order_id` (FK, nullable), `broker_order_id` (nullable), `broker_activity_id` (unique per account), `kind` enum (fill, sweep, dividend, interest, fee, deposit, withdrawal, transfer, corporate_action, other), `status` (Schwab's VALID/INVALID/PENDING; only VALID is journaled), `sub_type` string (raw Schwab type), `side`, `quantity`, `price`, `commission`, `fees` (summed from the activity's fee transfer items), `net_amount`, `trade_date`, `settlement_date`, `executed_at`, `raw` jsonb, `journaled_at` | yes |
| 11 | `setups` | `name` (unique), `definition`, `active` bool, `win_rate`, `avg_r`, `expectancy`, `sample_size`, `stats_computed_at`. Stats are stored here and recomputed by `Journal::RecomputeSetupStatsJob` whenever a trade closes; `get_setup_stats` reads them. | table yes, rows via seed |
| 12 | `trades` | `account_id`, `instrument_id`, `setup_id` (nullable), `order_proposal_id` (nullable), `status` enum (open, closed) only, with a partial unique index allowing one open trade per account and instrument, `needs_review` bool, `review_reason`, `excluded_from_stats` bool, `stopped_out` bool, `initial_quantity`, `total_risk` (orphan or bootstrapped, missing setup/stop), `bootstrapped` bool (created from an existing position, entry history unavailable), `opened_at` (nullable when bootstrapped), `closed_at`, `avg_entry`, `avg_exit`, `peak_quantity`, `planned_stop`, `planned_target`, `initial_risk`, `realized_pnl`, `realized_r`, `thesis`, `post_mortem`, `followed_setup` (nullable bool), `journal_completed_at` | yes |
| 13 | `trade_legs` | `trade_id`, `activity_id` (unique where present, nil on synthetic bootstrap legs), `kind` enum (entry, exit, adjustment, income), `quantity`, `price`, `ratio` (splits), `cash_amount`, `executed_at`, `note` | yes |
| 14 | `risk_rules` | `rule_type`, `params` jsonb, `active`, `version`, `setup_id` (nullable), `superseded_by_id` | no |
| 15 | `snapshots` | `account_id`, `as_of` date (unique per account), `equity`, `net_flows` (day), `daily_return` (net of flows), `index_value` (chain-linked, starts at 1.0), `high_water_index`, `drawdown` (fraction), `open_risk_amount`, `open_risk_ratio` (fraction of equity), `unprotected_count`. Fully rebuildable from `balances` + `transactions`. | yes |
| 16 | `audit_events` | `kind` string, `actor` enum (human/system/agent), `user_id` (nullable), `subject` polymorphic (nullable), `data` jsonb, `reason`, `created_at` only. Postgres triggers reject UPDATE, DELETE, and TRUNCATE; `kind` is validated against `AuditEvent::KINDS`. Reserved for the PRD's "logged" list; not telemetry. | yes |
| 17 | `market_days` | `date` (unique), `trading` bool, `session_opens_at` (pre-market), `regular_opens_at`, `regular_closes_at`, `session_closes_at` (post-market), `raw` jsonb, `fetched_at`, `source` enum (schwab, fallback) | yes |
| 18 | `sync_runs` | `feed` enum (accounts, positions, orders, activities, market_hours, memory_repo, snapshots; balances ride with positions), `account_id` (nullable; cursors are per account and feed), `status` (running, succeeded, partial, failed, skipped_token), `started_at`, `finished_at`, `error`, `records_touched`, `unmapped_values` jsonb, `window_from`, `window_to` (captured before the request; the next window starts from it), `gap_from` (set when the computed window start is later than the last success: data Schwab can no longer return) | yes |
| 19 | `agent_runs` | `kind` enum (morning_brief, eod, sunday_review), `status`, `degraded` bool (ran with expired token / stale data), `started_at`, `finished_at`, `tool_turns`, `input_tokens`, `output_tokens`, `estimated_cost`, `output_markdown`, `error`, `model` | yes |
| 20 | `tool_calls` | `agent_run_id` (nullable), `transport` enum (mcp, scheduled), `tool_name`, `arguments` jsonb, `duration_ms`, `error`, `created_at`. This is where MCP and runtime tool telemetry goes, not `audit_events`. | yes |
| 21 | `system_settings` | Singleton row (check constraint `id = 1`): `shadow_mode` bool default true, `manual_halt` bool default false, `manual_halt_reason`, `manual_halt_at`, `sync_paused_reason` (set while token expired) | yes |

Solid Queue / Cache / Cable schemas already generated. Every datetime column is `timestamptz` (adapter default set in an initializer). Schema format is `structure.sql` for the audit triggers; the dump pins Postgres 17 settings, so dokku runs the postgres:17 image. Active Record Encryption: production keys live in `config/credentials/production.yml.enc`; development and test share `config/credentials.yml.enc` (dev keys) with fixed test keys in `config/environments/test.rb`.

Phase 2 columns present now so `orders`/`order_proposals` never need a shape change: `parent_order_id`, `replaces_order_id`, `order_proposal_id`, `submission_unknown` state, `submission_attempts`, `guardrail_results`, `risk_rule_version`, `acknowledged_warnings`, `kind`/`target_order_id` for stop adjustments.

---

## 2. Jobs (Solid Queue, `config/recurring.yml`, all times America/New_York)

**Token model (revised after the step 4 counselors review).** Pause state is *derived* from the current token, never written by a failure. `schwab_tokens` gains `revoked_at`; `SchwabToken.current` is the newest by `issued_at, id`; `usable?` = present, not refresh-expired (`issued_at + 168.hours`, elapsed time not calendar days), not revoked. `SchwabToken.issue!(response)` inserts the new row and clears `system_settings.sync_paused_reason` in one transaction, enqueuing `Sync::CatchUpJob` after commit. `SchwabToken#refresh!` takes the row lock, reloads, and returns early if the row is no longer current or was refreshed in the last minute (so two workers cannot double-refresh and a stale row cannot act); it builds the client inside the lock; `access_expires_at` = now + `expires_in` − 60 s; `refresh_token` = response value or the existing one; `refresh_expires_at` is never touched. On `ReauthRequired` it sets `revoked_at` on the current row only, records `last_refresh_error` outside the lock so a rollback cannot lose it, audits `token_refresh_failed`, and sets `sync_paused_reason`. On `ServerError`/`TransportError` it records the error and does nothing else. `ensure_fresh!(margin:)` refreshes proactively when the access token is near expiry, so a 401 is the safety net rather than the norm. `Schwab.client` raises `Schwab::NoUsableToken` rather than letting nil reach a request.

**Token gating.** Only `Sync::TickJob` and the agent jobs are scheduled; everything else is enqueued by them. When `SchwabToken.current` is not usable, the tick job writes one `sync_runs` `skipped_token` row per hour, audits `sync_paused_token_expired` once per episode, and enqueues nothing. No self-re-enqueue, so the queue cannot grow. The re-auth callback (`issue!`) clears the pause, audits `sync_resumed`, and enqueues `Sync::CatchUpJob`, which runs all feeds with windows widened to cover the gap (capped at the 60-day limit). Agent jobs run degraded rather than wait: `degraded: true`, the prompt states the token is unusable and every number carries its as-of time, the email subject is prefixed, and the token status line sits at the top of every brief so a dead nag path is still visible daily. Snapshots are not written for days without a fresh balance.

**Re-auth flow.** `SchwabController#authorize` (login required) stores a random `state` with a timestamp in the session and redirects to the authorize URL. `#callback` (login required; an unauthenticated hit is rejected without storing a return-to URL, so the code never lands in the session) reads and deletes the pending state; no pending state renders "nothing pending, start again" with no audit; a mismatch audits `re_auth_failed` as CSRF; `params[:error]` (user cancelled) renders the failure without calling the token endpoint. On success: `exchange_code`, then `/accounts/accountNumbers` must overlap the known `accounts` hashes (first auth accepts anything) or the token is not made current and `re_auth_failed` is audited; then `issue!`, audit `re_auth_succeeded`, and **redirect** to a clean success page so a browser refresh cannot resubmit the single-use code. A failed exchange never writes to `schwab_tokens`. The retry link goes to `authorize`. `code`, `state`, and `session` join `filter_parameters`. The callback URL comes only from `SCHWAB_CALLBACK_URL`, never from the request. `fake_authorize` 404s unless the adapter is fake and the environment is not production, and `?fail=1` redirects with a bad code for Playwright.

**Health and nags.** `Schwab::TokenHealthJob` runs 08:00 and 20:00 ET. Nag when: no usable token (absent, revoked, or expired), sent at every run; or the 24-hour warning, sent once per token row (deduped on token id in the audit data). Monday/Tuesday escalation fires when `SchwabToken.current.issued_at` is before the most recent Sunday 18:00 ET, which is the PRD's literal "the Sunday re-auth hasn't happened"; no buffer, no comparison against the coming Sunday. Cron strings carry `America/New_York` explicitly. The refresh task gets a higher queue priority than sync.

| Job | Schedule | Does |
|---|---|---|
| `Schwab::RefreshAccessTokenJob` | every 25 min, high priority | `SchwabToken.current&.refresh!`; no-op when there is no usable token |
| `Schwab::TokenHealthJob` | daily 08:00 + 20:00 | See "Health and nags" above. Audits `token_nag_sent` with the token id and reason. |
| `Sync::TickJob` | every 5 min | Sole scheduled sync entry point. Refreshes `market_days` for today (New York) plus 7 days when missing or `source: fallback` (one call per date; a market-hours failure never aborts the tick). Due checks compare against the last *started* run per account and feed with 1-minute slack, and a `running` run is never due; jobs also declare Solid Queue `limits_concurrency` keyed on account and feed so backlog cannot double-enqueue. Cadences apply to trading-enabled accounts: positions (15 min inside the session window pre-market through post-market, 60 min otherwise), orders and activities (5 min inside, 60 outside); read-only accounts sync hourly. `Snapshots::DailyJob` once per market day after `regular_closes_at` + 20 min, only when that day's calendar row came from Schwab. |
| `Sync::AccountsJob` | daily 06:05, after every re-auth | `/accounts/accountNumbers` only; upsert by `schwab_hash`. New accounts land with `trading_enabled: false` and no `account_type`; the system screen shows accounts needing operator setup |
| `Sync::PositionsJob(account)` | via tick | `/accounts/{hash}?fields=positions`; resolve instruments (§2 "Instrument identity"); upsert positions; append a `balances` row; delete positions absent from the response only when the run is complete (every position resolved) and the payload is sane (no positions with positive long market value is a `failed` run, not an empty account); then `Journal::BootstrapJob` for trading-enabled accounts |
| `Sync::OrdersJob(account)` | via tick | Window: from = max(last `window_to` for this account − 1 day, now − 364 days), to = end of the current UTC day (bounds may be date-granular; verify item). First sync backfills a year (live probe confirmed the window). Flatten nested orders and upsert in two passes (rows, then lineage by broker id); container strategies are stored with no instrument; exactly 3000 rows means truncation and finishes `partial`. Any `positions.working_stop_order` not present in the response is re-fetched by id (covers old GTC stops, out-of-band cancels, and replacements outside the window). A daily `status: WORKING` pass. Then working-stop detection (§5) for every position, only on a complete run; a failed or partial run leaves stop assignments untouched |
| `Sync::ActivitiesJob(account)` | via tick | One call per transaction type the cash account can produce (TRADE, RECEIVE_AND_DELIVER, DIVIDEND_OR_INTEREST, ELECTRONIC_FUND, ACH_RECEIPT, ACH_DISBURSEMENT, WIRE_IN, WIRE_OUT, JOURNAL, CASH_RECEIPT, CASH_DISBURSEMENT, MONEY_MARKET), cursor per account and feed: from = max(last `window_to` − 3 days, now − 364 days), to = end of the current UTC day. A `RequestError` on one type skips that type and finishes `partial`; 429, 5xx, and transport failures leave the cursor alone. Upsert by `broker_activity_id`, link `order_id` via the activity's orderId, classify `kind` (§2 "Activity kinds"); then `Journal::LinkFillsJob` |
| `Sync::CatchUpJob` | after re-auth | Bypasses due checks: accounts, then per account positions, orders (with the WORKING pass), activities. Windows already derive from the last `window_to`, so a short pause needs nothing special; when the computed start is later than the last success, the run records `gap_from` and audits `sync_gap_unrecoverable` so nobody believes the catch-up was complete |
| `Journal::BootstrapJob` | after positions sync | See §4 |
| `Journal::LinkFillsJob` | after activities sync | See §4 |
| `Journal::RecomputeSetupStatsJob` | after any trade closes | Rolling stats onto `setups` |
| `Snapshots::DailyJob` | via tick | See §6 |
| `Jobs::FailureDigestJob` | daily 17:00 | One email listing failed `sync_runs`, `agent_runs`, and Solid Queue failed executions since the last digest, grouped by kind |
| `Memory::PullRepoJob` | every 30 min | `git -C $MEMORY_REPO_PATH pull --ff-only`; record `sync_runs` |
| `Agent::MorningBriefJob` | 07:00 market days | See §3 |
| `Agent::EndOfDayJob` | 16:30 market days | See §3 |
| `Agent::SundayReviewJob` | Sunday 18:00 | Phase 1 stub, no API call: re-auth link, token age, sync health, job failures, setup stats table |

**Sync runs.** `SyncRun.record(feed, account:, window:)` wraps every feed: creates the row, captures `window_to` before the request, rescues `NoUsableToken`, `AuthError`, and `ReauthRequired` into `skipped_token`, rescues other `Schwab::Error` into `failed`, counts quarantined records into `partial` with `unmapped_values` (raw type, description, subAccount, sign, item shape), and stamps `records_touched`. `partial` advances the cursor; `failed` does not. A cash-affecting `other` activity makes the run `partial`, never a quiet success.

**Instrument identity** (`Instrument.resolve(ref)`): CUSIP, then Schwab instrument id, then symbol plus asset type **matching only rows with no CUSIP**, then an `instrument_by_symbol` lookup, then create a provisional row. A weaker-key match backfills a missing CUSIP or instrument id from the ref but never overwrites a differing one. A CUSIP match with a different symbol calls `rename!`. The `instrument_identity_fallback` audit fires once, when a provisional row is created, not on every resolve. `RecordNotUnique` is handled with a re-lookup because positions and activities race.

**Activity kinds.** TRADE with an EQUITY security → `fill`; TRADE with a CASH_EQUIVALENT security or MONEY_MARKET → `sweep`; DIVIDEND_OR_INTEREST → `dividend` when a security is present, else `interest`; ELECTRONIC_FUND, ACH_*, WIRE_*, CASH_* and JOURNAL with only currency items → `deposit` or `withdrawal` by sign; JOURNAL or RECEIVE_AND_DELIVER with one security → `transfer` (ACAT deliveries are not corporate actions), with two securities → `corporate_action`; all items fees → `fee`; anything else → `other` and counted. Activities whose `status` is not VALID are stored and never journaled.

**Market calendar.** `MarketDay.for(date)` reads the row or fetches it (source schwab). When the token is unusable or the call fails it writes a weekday-open 9:30 to 16:00 row with `source: fallback`, which drives cadence only: snapshots and market-day briefs require a Schwab-sourced row, and fallback rows are re-fetched on every tick until they flip. "Today" is computed in America/New_York.

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

## 4. Journal builder (zero-to-zero, trading-enabled accounts only; revised after the step 6 counselors review)

IRA and other read-only accounts sync positions and activities (for Phase 2 wash-sale checks) but never create trades. `Journal::BootstrapJob` and `Journal::LinkFillsJob` share one Solid Queue concurrency key per account, and every activity is linked in its own transaction: insert or find the leg by `activity_id`, recompute the trade as a pure function of its legs, then stamp `journaled_at` last. A rerun finds the existing leg and recomputes; it never skips because the activity was marked.

**Bootstrap** (`Journal::BootstrapJob`, after every complete positions sync). Every open position in a trading-enabled account has one open trade. Its synthetic `entry` leg is a **reconciling plug**: quantity = broker quantity − net quantity of the linked fill legs, priced at the broker average price, recomputed after every bootstrap and link run and deleted when it reaches zero. A trade whose plug is non-zero is `bootstrapped: true, needs_review: true, review_reason: bootstrapped`, with `opened_at` nil. Positions with zero quantity or no average price are skipped. After a complete positions sync, an open trade whose instrument has no position and no unjournaled fills is flagged `review_reason: position_missing`.

**Link fills** (`Journal::LinkFillsJob`), per account and instrument, VALID unjournaled activities in `executed_at, id` order:
- Buy fill, no open trade: open one. If `activity.order.order_proposal` resolves, copy setup, thesis, planned stop, and target; else `needs_review` with `review_reason: missing_setup`.
- Sell fill, no open trade: open a bootstrapped trade whose plug covers the pre-sale holding (position quantity + sold quantity when the position exists, else the sold quantity with `review_reason: bootstrapped`), then apply the exit.
- Every fill is an `entry` or `exit` leg carrying `cash_amount` = the activity's signed `net_amount` (which already includes commissions and fees). Running quantity, `avg_entry`, `avg_exit`, `peak_quantity` are recomputed from legs.
- Running quantity reaches zero: `status: closed`, `closed_at`, `realized_pnl` = sum of leg cash amounts (entries negative, exits and income positive; fees are never subtracted again), `stopped_out` when the closing exit's order was a stop type.
- Out-of-order arrival: when a newly linked activity precedes the latest leg on that instrument, the instrument's fills are replayed from scratch. Same-day fills with date-only timestamps are linked but flagged `review_reason: ordering_ambiguous`.
- A re-synced activity whose quantity, price, or status changed after journaling has its leg dropped and `journaled_at` cleared, then the instrument replays.
- Dividend or interest on an instrument with an open trade: `income` leg (feeds realized P&L, not basis). After close, attach to the most recent closed trade on that instrument within 90 days and recompute; otherwise journal with no leg. Return of capital is treated as income in Phase 1.
- Instrument-bearing `transfer` with an open trade (forward split, stock dividend, ACAT delivery): `adjustment` leg with ratio derived as (running + delivered) / running; quantity × ratio, prices ÷ ratio, `initial_risk` unchanged. Ratios that are not clean are flagged `review_reason: corporate_action`.
- `corporate_action` with two securities (CUSIP succession): both securities are read from the activity's `securities`; set `predecessor_instrument_id` on the new instrument and move the open trade to it with an adjustment leg. An unreviewed bootstrapped trade already on the new instrument is absorbed by the moved trade. Unmatched halves fall back to exit/entry with `review_reason: corporate_action`.
- Symbol change on a known CUSIP: `rename!` only.
- Sweeps, deposits, withdrawals, fees, and cash-only transfers: `journaled_at` set, no leg.
- A fill with no side or an unresolved instrument is quarantined on the sync run, never raised.

**R math.** `initial_quantity` = every entry fill sharing the first entry's `order_id` (fallback: all entries before the first exit), so a partial fill does not understate risk. `initial_risk` = `initial_quantity` × (average initial entry price − `planned_stop`), fixed once the stop is known; at or below zero it is nil and so is R. `realized_r` = `realized_pnl` / `initial_risk`. `total_risk` = sum over entry legs of quantity × (price − stop at that time), stored for the journal browser, never used as the R denominator. A bootstrapped trade closed before review takes setup and thesis only; its R stays nil.

**Review path.** `review_reason` enum (missing_setup, missing_stop, bootstrapped, ordering_ambiguous, corporate_action, position_missing) drives the Monarch-style queue with Skip / Not a trade / Save. Save takes setup, planned stop, and thesis, clears `needs_review`, computes `initial_risk`, and audits `trade_reviewed`. Not a trade sets `excluded_from_stats`. The post-mortem quick entry (one line plus followed/improvised) is separate and available on any closed trade.

**Setup stats** (`Journal::RecomputeSetupStatsJob`, after a trade closes, is reviewed, or is excluded): over closed trades with a positive `initial_risk`, not `needs_review`, not `excluded_from_stats`, and not bootstrapped-without-stop-at-entry: win rate (R > 0), average R, expectancy (mean R), sample size. Trailing-20 trend is deferred to the edge-review screen in Phase 2 and the plan says so.

---

## 5. Stops and open risk in Phase 1

No stop is not zero risk. On every complete orders sync, for each position the working stop is chosen from sell stop orders (STOP, STOP_LIMIT, TRAILING_STOP, TRAILING_STOP_LIMIT) on the same account and instrument that are the terminal order of their replacement chain and in a working status, preferring live statuses (WORKING, ACCEPTED, QUEUED, PENDING_ACTIVATION) over AWAITING_* so a new bracket child cannot displace the stop on an existing lot. The newest such order is assigned regardless of whether it carries a readable price; the model decides what that means. A stop missing from the list response is re-fetched by id before it is considered gone.

- Protected: a working stop with a readable price whose remaining quantity covers the position. Distance to stop = (last − stop) / last, signed; open risk = max(quantity × (last − stop), 0).
- Partially protected: remaining stop quantity below the position quantity. Shown as such, counted as unprotected in the portfolio total.
- Oversized: remaining stop quantity above the position quantity. Schwab will reject the whole order at activation in a cash account, so this is flagged unprotected with its own reason (PRD §5.4.2 hard-alert case).
- Trailing stop without a price: unknown risk, labelled "trailing stop, price unknown".
- No stop, or a stop no longer working: unprotected.
- Portfolio open risk sums protected positions only, and the dashboard and `get_account_health` state how many positions are excluded and why.

---

## 6. Snapshots (per account, chain-linked; revised after the step 6 counselors review)

For each trading-enabled account and each market day with a Schwab-sourced calendar row:
- `equity` = the latest balance at or after the regular close on that day, else the day's latest balance, else **no snapshot** (a stale balance is never smeared across days). The first snapshot is the first day with positive equity, with return 0 and index 1.
- `net_flows` = every deposit and withdrawal with `trade_date` after the prior snapshot's date and up to this one, so a flow that lands on a paused or missing day is still neutralized. Deposits positive, withdrawals negative, classified by type for the directional types (ACH_RECEIPT, WIRE_IN, CASH_RECEIPT in; ACH_DISBURSEMENT, WIRE_OUT, CASH_DISBURSEMENT out) and by sign only for ELECTRONIC_FUND and JOURNAL, with a disagreement quarantined. Share transfers are valued at quantity × that day's position price when known, else the day is flagged.
- `daily_return` = (equity − net_flows − prior equity) / prior equity; `index_value` = prior index × (1 + daily_return); `high_water_index` = max to date; `drawdown` = 1 − index / high_water_index.
- `open_risk_amount`, `open_risk_ratio`, `unprotected_count` from §5 at snapshot time.
- Rebuildable: `Snapshots::RebuildJob(account, from:)` recomputes forward. The activities sync captures `new_record?` before each upsert and enqueues a rebuild from the earliest new or changed cash-affecting activity date; the positions sync enqueues one from any balance row it inserts for a day that already has a snapshot.

Dashboard day change is flow-adjusted (equity − flows − prior snapshot equity) and reads "no prior snapshot" on a gap day. The EOD fills recap reads activities journaled today; the missing-post-mortem list excludes `needs_review` and `excluded_from_stats` trades.

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

- `Procfile`: `web: bundle exec puma -C config/puma.rb`, `worker: bin/jobs`, `release: bin/rails db:prepare`. One Postgres 17 service and one database: Solid Queue, Solid Cache, and Solid Cable tables live in the primary schema (migration `InstallSolidTables`), so `db:prepare` on `DATABASE_URL` is the whole database setup.
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
