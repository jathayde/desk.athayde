**Findings**

Critical: [docs/phase-2-plan.md](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2-plan.md:76) puts approval UI before submission, and [line 42](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2-plan.md:42) models `approve!` separately from `submit!`. Flow 2 says the deliberate approve confirm is the moment the order goes to Schwab. Split approval creates an exposed `approved` state that can be submitted later by code outside the operator’s gesture. The plan needs one `approve_and_submit` command: row lock, fresh guardrail eval, audit approval, create attempt, then shadow/live submit.

Critical: shadow submission is not terminal enough. [line 46](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2-plan.md:46) says shadow audits `would_have_submitted`, but does not say the proposal leaves `approved`. If it stays approved, a double click or reload can create duplicate shadow attempts, and the same bug becomes duplicate live orders when shadow is off. Add a DB-level invariant: at most one non-failed attempt per proposal, and `would_have_submitted`, `submitted`, and `unknown` must move the proposal out of approvable state under the same lock.

Critical: build order lets unsafe approvals happen before wash-sale/tax-lot work. [line 78](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2-plan.md:78) defers wash sale until after approval/submission. PRD §5.4 makes wash-sale awareness a starting guardrail, and UI Flow 2 names it as a warning requiring acknowledgement. Wash sale must be in the evaluator before any approve control ships.

High: unavailable guardrails are underspecified. Sector and earnings/econ are marked `unavailable` in [line 11](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2-plan.md:11), but approval behavior is not defined. “Shown, never treated as pass” is not enough. Either unavailable blocks entries, or the PRD must explicitly accept that Phase 2 can approve with unknown sector/blackout risk. As written, the operator can approve an earnings-adjacent or over-sector trade with a table row that looks non-fatal.

High: settled-cash projection is too narrow. [line 34](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2-plan.md:34) subtracts pending approved buys, but should reserve all unfilled app buy exposure plus relevant live broker buy orders, including shadow/live state distinctions, partial fills, stale balances, and token-expired cases. If the balance is stale or the settled-cash mapping is unverified, the cash rule should hard fail, not warn. Verify [docs/verify-on-approval.md](/Users/jathayde/Development/Personal/desk.athayde/docs/verify-on-approval.md:10) item 10 before Step 1, not later.

High: Schwab order-shape verification is too late. Before Step 4, verify enough to build and reconcile deterministically: bracket `TRIGGER` shape, parent/child `orderStrategyType`, stop child activation/status, `Location` header/order id behavior, order list filters/time precision, order detail by id, and the fields needed to match an ambiguous POST by account, instrument/CUSIP, side, quantity, order type, limit/stop, session/duration, and entered window. Tax-lot enum, trailing-stop child support, fractional quantities, write rate limits, and cancel/replace can be shadowed until those features go live, but not before disabling shadow.

Medium: the state machine contradicts Phase 1 shells. Phase 1 already created proposal statuses; Phase 2 adds `rejected_by_rules` and `expired` in [line 42](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2-plan.md:42) without listing the enum migration in the data model. Also normalize `reject_reason` vs `rejection_reason`. Add specs for every legal/illegal transition plus DB constraints for “approved requires no hard fail,” “submitted requires an attempt,” and “filled/cancelled only via sync.”

Medium: collar failure modes need teeth. [line 38](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2-plan.md:38) defines calculations, but not side validation, zero/negative per-share risk, stale quotes, insufficient candles, or unavailable market data. Bad or missing collar data should block entry approval; only “computed and outside range” should be overrideable.

Medium: Phase 2 scope contradicts the PRD on iOS/push. PRD §6 includes Hotwire Native app, push, and Face ID confirm in Phase 2. The plan ships Rails-side iOS last and explicitly excludes the Xcode project. Either update the PRD/decisions log or make the app a real Phase 2 deliverable.

**Required Build Order**

1. Resolve Phase 1 deferred prerequisites: settled-cash derivation, one trading account invariant, `risk_rules` active uniqueness, audited tool metadata, write gate semantics.
2. Schema/state machine/audit constraints, including idempotency DB constraints.
3. Full approval-blocking guardrails: settled cash, halt, notional, max risk/positions/exposure, wash sale, collar, unavailable behavior.
4. Collar/sizing.
5. Tools/manual proposal/detail UI, but no approve button until `approve_and_submit` exists.
6. Shadow submission/reconciliation/protection alerts.
7. Rule editor, watchlist, notifications, Playwright, iOS decision.
