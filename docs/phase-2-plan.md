# Phase 2 plan: propose and approve (shadow mode on)

Source of truth: `docs/artifacts/investment-copilot-prd.md` §5.4, §5.4.1, §5.4.2, §5.5, §5.8, §5.8a, §6, §7, §8; screens in `investment-copilot-ui-flows.md` Flows 2, 3, 6, 7 and the wireframes. Phase 1 (`docs/phase-1-plan.md`) is deployed; its conventions hold (secrets in credentials, no plaintext account numbers, CUSIP identity, every "logged" action an `audit_events` row, no live Schwab calls in tests, unattended runs read-only, `bin/ci` green per step, DHH and counselors review per step). Equities only (PRD §8). Nothing in this phase auto-executes: the only path to Schwab's order endpoint is the human approval in the Rails UI, under shadow mode until turned off deliberately.

## 0. Decisions and assumptions (revise after the counselors review)

1. **Shadow mode stays on for the whole phase.** `SystemSettings#shadow_mode` is true by default in production; turning it off is a deliberate toggle on the system page with a typed confirmation, audited (`shadow_mode_toggled`, already a kind). In shadow mode the approval path runs end to end and the submission step writes a `would_have_submitted` audit event with the exact payload instead of calling Schwab. The number of shadowed approvals that must reconcile before it is turned off is the operator's call, shown on the system page as a count.
2. **Bracket = Schwab `TRIGGER` strategy**: an entry order whose `childOrderStrategies` carries one `STOP` sell for the same quantity (`# SCHWAB_SHAPE_UNVERIFIED`: strategy type name, child shape, whether a `TRAILING_STOP` child is accepted; confirmed only by a shadowed payload compared against schwab-py's order builder and then by the first live submission). `docs/verify-on-approval.md` gets a Phase 2 section.
3. **Order payload builder lives in the Schwab namespace** (`Schwab::OrderPayload`) like every other Schwab shape; the proposal model never spells a Schwab field name. `Schwab::Client#place_order(hash, payload)` returns the new order id from the `Location` header (`# SCHWAB_SHAPE_UNVERIFIED`); `#cancel_order` and `#replace_order` for stop adjustments.
4. **Idempotency is local (PRD §5.1):** `approved → submitted` runs under `SELECT ... FOR UPDATE` on the proposal row, is the only code path that calls `place_order`, records a `submission_attempts` row before the call, and on timeout, 5xx, or a dropped connection after send moves the proposal to `submission_unknown`. `Submission::ReconcileJob` searches the orders endpoint for a match (instrument, side, quantity, order type, price, entered within the attempt window) before any retry; no retry without a reconcile that found nothing. A found order links back (`reconciled_order_id`) and the proposal becomes `submitted`.
5. **Guardrails are data** in `risk_rules` (`rule_type`, `params`, `active`, `version`, `setup_id`, `superseded_by_id`): edits create a new version and supersede the old, never update in place. Evaluation results are stored on the proposal (`guardrail_results` jsonb: one entry per rule with `outcome` pass, warn, fail, or unavailable, plus the numbers) and audited (`proposal_evaluated`). Rules 2b (sector exposure) and 5 (earnings and econ blackout) evaluate to `unavailable` in Phase 2 because there is no sector or calendar source yet (FMP is Phase 2.5); `unavailable` is shown, never treated as pass.
6. **Sizing is computed by Rails, never by the agent** (PRD §10): quantity = floor(risk budget ÷ (entry − stop)), risk budget = max-risk-per-trade % × equity from the latest balance; whole shares only (fractional support unverified). The agent proposes symbol, side, entry type and price, stop, thesis, setup; Rails fills the quantity and the collar.
7. **Stop collar (§5.4.1)** computed from Schwab daily price history through `Agent::MarketData` (cached, budgeted): ATR(14) multiple, swing low over N bars minus a buffer, percent stop, chandelier (reference only). Parameters per setup in `risk_rules` rows of type `stop_collar`. Data-quality checks: at least 30 daily candles, latest candle within two trading days, a fresh quote. A stop outside the collar is a `warn` needing an override reason; rules 1 to 4 and 7 are hard `fail`.
8. **Wash sale (§5.4 6)**: a loss realized on the same instrument (CUSIP) within the last 30 days in this account or the linked IRA (its activities already sync) warns or blocks per the rule's `mode`; instrument match only, and the UI says so. **Tax lots (6a):** every sell proposal carries `tax_lot_method` (FIFO default; enum `# SCHWAB_SHAPE_UNVERIFIED`) shown on the detail with the lots' short or long-term status computed from the journal's open legs.
9. **Write tools exist only on the interactive transport** (`mcp: true, scheduled: false, read_only: false`) and every call is an `audit_events` row as well as a `tool_calls` row (`Agent::Tool` gains `audited`, the registry writes the event): `propose_order`, `annotate_trade`, `add_watchlist_item`, plus the read tool `evaluate_hypothetical_order`. `submit_order`, `cancel_order`, `edit_risk_rules`, and token operations do not exist as tools.
10. **Notifications in Phase 2 are email** (new proposal, fill or cancel, halt tripped, unprotected position, submission unknown), each a short mail with a deep link and no dollar figures in the subject; push arrives with the iOS shell (§12) and replaces them for the time-sensitive set.
11. **iOS is the last step of the phase** and only its Rails side is in this repo: Hotwire Native path configuration, a device registration endpoint, and APNs delivery. APNs needs a gem outside Rails defaults (candidate `apnotic`); that is a decision for the morning, not this plan. The Xcode project is a separate repository.
12. **Halts block new proposals, not exits** (§5.4 3): a daily-loss or drawdown halt, or the manual halt, refuses `propose_order` and the manual form for entries and allows sell proposals through.
13. **Every state change on a proposal is an audit event** with the actor: `proposal_created`, `proposal_evaluated`, `proposal_approved` (with acknowledged warnings and any override reason), `proposal_rejected`, `proposal_submitted`, `would_have_submitted`, `submission_unknown`, `submission_reconciled`, `proposal_expired`, `proposal_cancelled`, `rule_changed` (before and after), `shadow_mode_toggled`, `unprotected_alert_sent`.

## 1. Data model (§5.2; new columns and tables need the user's nod, listed here for the review)

| Table | Change |
|---|---|
| `order_proposals` (exists) | add `collar` jsonb (method values, bounds, where the stop sits), `sizing` jsonb (equity, risk budget, per-share risk, quantity), `override_reason` text, `evaluated_at`, `approved_at`, `approved_by_id`, `rejected_at`, `rejected_by_id`, `rejection_reason`, `submitted_at`, `expires_at`, `shadow` boolean (was submitted under shadow mode), `submitted_order_id` (the broker order the sync linked), `parent_proposal_id` (a stop adjustment points at the entry it adjusts) |
| `submission_attempts` (exists) | as is; `outcome` enum submitted, would_have_submitted, unknown, failed |
| `risk_rules` (exists) | add `mode` (block or warn, for wash sale), `note` text, `changed_by_id`; unique index on `(rule_type, setup_id)` where `active` with `NULLS NOT DISTINCT` |
| `watchlist_items` (new) | `instrument_id` (nullable until resolved), `symbol`, `trigger` text, `thesis` text, `origin` (agent or human), `user_id`, `status` (watching, triggered, dropped), timestamps |
| `push_devices` (new, §12) | `user_id`, `token` (encrypted), `platform`, `last_seen_at` |
| `orders` | `order_proposal_id` (exists as lineage) is set by the submission and by reconciliation; `placed_via` becomes `app` for orders the app placed |

## 2. Guardrail engine

`Guardrails::Evaluator.new(proposal).call` returns a `Guardrails::Report` (one `Result(rule, outcome, detail)` per active rule, `blocked?`, `warnings`, `needs_override?`) and is the only thing that writes `guardrail_results`. Rules are `Guardrails::Rule` subclasses keyed by `rule_type`, each `evaluate(proposal, context)` over a `Guardrails::Context` (equity and settled cash from the latest balance, open positions and their risk, today's realized P&L and the drawdown from snapshots, pending approved proposals projected onto cash, recent losses for wash sale, the collar): `max_risk_per_trade`, `max_positions`, `max_position_exposure`, `max_sector_exposure` (unavailable), `daily_loss_halt`, `max_drawdown_halt`, `settled_cash` (a buy must be fully covered by settled cash minus pending approved buys), `earnings_blackout` (unavailable), `wash_sale`, `notional_cap` (per order and per day, counting today's approved and submitted proposals), `stop_collar`. Evaluation runs on create, again on approve (a stale evaluation is refused: cash or positions changed), and on demand from the detail page. `evaluate_hypothetical_order` runs the same evaluator over an unsaved proposal and returns the report without writing anything.

## 3. Stop collar

`StopCollar::Calculator.new(instrument, entry_price:, setup:)` pulls one year of daily candles (`Agent::MarketData.price_history`, range `1y`) and the current quote, checks data quality, computes every enabled method from the setup's `stop_collar` rule params (`atr_k`, `swing_bars`, `swing_buffer_atr`, `percent`, `chandelier_bars`, `chandelier_k`), and returns `Collar(methods:, tight:, wide:, floor:, quality:)`. The percent stop is the floor: a stop below it is outside the collar whatever the other methods say. `StopCollar::Trail` recomputes chandelier and ATR trails for open positions nightly (`StopCollar::TrailJob`, 17:00 New York) and stores a `suggested_stop` per position for the EOD brief's "tighten stop" line; adjusting the real stop is a stop-adjustment proposal (kind `stop_adjustment`, target the working stop order, replace-only-tighter unless a human types a reason).

## 4. Proposals

`OrderProposal` states: `proposed` (created, evaluating), `validated` (no hard fail), `rejected_by_rules`, `approved`, `submitted`, `submission_unknown`, `filled`, `cancelled`, `rejected` (by the human), `expired`. Kinds: `entry` (buy with a child stop), `exit` (sell), `stop_adjustment`. Origin `agent` (through `propose_order`) or `human` (Flow 3 form). Transitions live on the model (`approve!(user:, acknowledged:, override_reason:)`, `reject!`, `submit!`, `expire!`), each audited, each refusing from the wrong state. Proposals expire at the end of the market day they were created on (`ProposalExpiryJob` via the tick after the close). The queue is `/proposals` (Flow 2 list), the detail `/proposals/:id` with the evaluation table, the collar with the stop marked, the sizing, the thesis and setup, the lots on a sell, the warnings to acknowledge, the override reason field, and the approve and reject forms (web: a typed confirmation word; iOS later: Face ID). The manual form is `/proposals/new` (Flow 3) with the collar and sizing recomputed on each change through a Turbo frame, no JavaScript beyond Turbo.

## 5. Submission

`Submission::Submit.new(proposal, user:).call`: lock the row, refuse unless `approved` and `SystemSettings#writes_allowed?` for the real path (the manual halt blocks entries even in shadow mode; shadow mode itself is the gate between `would_have_submitted` and a real call), re-evaluate and refuse on a fresh hard fail, build `Schwab::OrderPayload.bracket(proposal)` (or `.sell`, `.replace_stop`), write the `submission_attempts` row with the payload, then either audit `would_have_submitted` (shadow) or call `place_order`. Outcomes: an order id → `submitted`, the attempt `submitted`, the next orders sync links the order and its child by `order_proposal_id`; a 4xx → `failed` on the attempt and the proposal back to `approved` with the error shown; a timeout, 5xx, or dropped connection after send → `submission_unknown` and `Submission::ReconcileJob` enqueued (retries at 1, 5, 15 minutes; then the operator sees "unknown, check Schwab" on the queue and the system page until resolved). `Orders::ProtectionWatch` runs in the orders sync: a parent filled with no live child stop, or a working stop gone at the broker, sends the unprotected alert email once per position and audits it.

## 6. Wash sale and tax lots

`WashSale.losses_within(instrument, 30.days, accounts: [trading, ira])` reads closed trades with a negative realized P&L in the trading account and sells at a loss in the IRA's activities (the IRA has no journal; its fills are matched by CUSIP against its own average cost, which is an approximation the detail page states). `TaxLots.for(trade)` lists open entry legs with their acquisition dates and short or long-term status; a sell proposal shows them and carries `tax_lot_method`.

## 7. Write tools and the registry

`Agent::Tool` gains `audited:`; `Agent::Tools.call` writes an `audit_events` row for an audited tool with the arguments (never the account hash). `Agent::Tools::ProposeOrder` (creates the proposal through the same service the form uses, returns the evaluation report and the proposal id; refused during a halt for entries), `AnnotateTrade` (post-mortem text on a trade, appended not replaced, audited), `AddWatchlistItem`, `EvaluateHypotheticalOrder` (read-only, no row). `Agent::Tools.for(:scheduled)` is unchanged by construction: the scheduled runtime never sees a write tool, and the existing eager-load check keeps it that way.

## 8. Rule editor and watchlist

`/risk_rules` (Flow 6, desktop-first, still renders on a phone): one row per active rule with its params, a form that creates the next version and supersedes the current, an effect preview (the evaluator run over today's open positions and pending proposals with the new rule), and a lock while a halt is engaged with the override path (engage the kill switch, type a reason, edit). `/watchlist` (Flow 7): items from the tool and the form, each with its trigger and thesis, a link to propose from it, and the morning brief's "watching" section reads the table (the memory repo's `watchlist.md` stays as narrative text).

## 9. Notifications

`AlertMailer`: `new_proposal`, `fill_or_cancel`, `halt_tripped`, `unprotected_position`, `submission_unknown`; each sent once per event, audited, no figures in subjects, deep links only. The failure digest gains the submission attempts that failed.

## 10. Screens

Proposal queue and detail (mobile-first), manual proposal form, rule editor, watchlist, the shadow-mode and halt controls on the system page with the shadowed-approval count, the dashboard's "pending proposals" line and the unprotected hard alert banner, the EOD brief's fills recap linking fills to proposals, and the journal's trade detail showing the originating proposal. Playwright scenarios for the queue with a warn, a hard fail, an override, an approved-in-shadow proposal, and a submission unknown.

## 11. iOS (Rails side only)

`GET /native/path_configuration.json` (Hotwire Native routes: proposal detail, dashboard, journal entry as native-tabbed, everything else modal or web), `POST /native/devices` (registers the APNs token for the session's user, encrypted at rest), and `Push::Deliver` behind the same `AlertMailer` events so each alert goes to push when a device exists and to email otherwise. Face ID as the approve confirmation is the shell's job; the Rails approve endpoint accepts the same typed confirmation from the web and a signed native confirmation header from the shell (`# VERIFY: Hotwire Native bridge component contract`).

## 12. Build order (green `bin/ci`, DHH and counselors review, commit per step)

1. Schema for proposals, rules, watchlist; `OrderProposal` states and audits; `Guardrails` engine with rules 1, 2a, 3, 4, 7 and the halt gate; `evaluate_hypothetical_order`; seeds for a rule set.
2. Stop collar calculator and the `stop_collar` rule; sizing; the nightly trail job and the EOD "tighten stop" line.
3. `propose_order` through the registry with audited write tools; the manual form; the queue and detail with approve, reject, acknowledge, override; expiry.
4. Submission in shadow mode: payload builder, the locked submit path, `submission_attempts`, `would_have_submitted`, `Schwab::Client#place_order/cancel_order/replace_order` with cassettes marked unverified, the reconcile job, orders linkage, the unprotected alert, the shadowed-approval count.
5. Wash sale and tax lots; `annotate_trade` and `add_watchlist_item`; the watchlist screen; the brief's watching section.
6. Rule editor with versions, preview, and the halt override path; shadow-mode toggle with typed confirmation.
7. Alert mailer and the digest additions; the dashboard and journal proposal lines; Playwright scenarios; phase-level DHH and counselors review.
8. iOS Rails side (path configuration, device registration, push delivery) once the APNs gem decision is made.
9. Phase 2.5 (allocation module) gets its own plan after this phase ships.

## 13. Not built in Phase 2

Real submission with shadow mode off (the operator's toggle, after reconciled shadow approvals), options, FMP and the earnings and econ calendar (rules 2b and 5 stay `unavailable`), the allocation module, Phase 3 auto-submit, the Xcode project.

## 14. Verify on approval (Phase 2 additions to `docs/verify-on-approval.md`)

The bracket strategy type and child order shape; the `Location` header on order POST; `taxLotMethod` enum values; order endpoint rate limits; whether fractional quantities are accepted; the order search parameters the reconcile job can filter on; `TRAILING_STOP` child acceptance; replace-order semantics for a tighten-only adjustment.
