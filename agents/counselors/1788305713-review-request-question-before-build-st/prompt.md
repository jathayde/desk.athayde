# Second Opinion Request

## Question
# Review Request

## Question
Before build step 7 (the Phase 1 web screens: dashboard with four banner states, system health, trade review and post-mortem, plus Playwright) is written, review the screen design against the PRD and the UI flows doc, and find what the screens need from the data model that Phase 1 does not produce.

## Context

### PRD, flows, and plan
- @docs/artifacts/investment-copilot-prd.md §5.8 (UI), §5.8a (iOS later: keep screens mobile-responsive, no full-page JS routers, no hover-dependent modals), §5.9 (shadow mode indicator), §5.10 (health page shows token age and Sunday cadence)
- @docs/artifacts/investment-copilot-ui-flows.md Flow 1 (dashboard states and content), Flow 4 (journal entry), Flow 8 (system health and kill switch), cross-cutting states (stale data marks, token expired read-only mode, empty states), the Monarch and Midday/Mercury/Origin reference notes (distance-to-stop as the primary number, unprotected inline warning, freshness stamps, orphan review modal with N-more-to-review, sparkle glyph on agent-authored content)
- @docs/artifacts/investment-copilot-wireframes.html (Flow 1 frames, Flow 4 frame, Flow 8 frame)
- @docs/phase-1-plan.md §7 (screens table, app mark, banner precedence), §8 (Playwright scenarios), §5 (protection states)

### What exists
Models and jobs from steps 2 through 6: Account (trading_enabled, account_type nullable), Position (#protection returning :protected/:partial/:oversized/:awaiting/:trailing_unknown/:unprotected, #distance_to_stop, #open_risk, synced_at), Balance (equity, settled_cash, unsettled_cash, as_of), Order, Activity, Trade (status, needs_review, review_reason enum, bootstrapped, excluded_from_stats, stopped_out, planned_stop, avg_entry/avg_exit, realized_pnl, realized_r, post_mortem, followed_setup, review!, exclude!), Setup (stats), Snapshot (equity, daily_return, index_value, high_water_index, drawdown, open_risk_amount, open_risk_ratio, unprotected_count), SchwabToken (usable?, refresh_expiring_soon?, revoked?, age via issued_at), SystemSettings (shadow_mode, manual_halt, manual_halt_reason, sync_paused_reason), SyncRun (per feed and account, status, started_at, finished_at, error), AgentRun (estimated_cost; table exists, populated in step 9), MarketDay, AuditEvent. Magic-link login with two users. Layout shell with the Athayde crest. Schwab::FakeClient with a scripted queue and a fake authorize page; a test-only scenario route is planned for Playwright.

### Planned step 7 design
- `DashboardController#show`: banner precedence halted > expired > expiring > healthy from SystemSettings.manual_halt, SchwabToken.usable?, and refresh_expiring_soon?; equity and flow-adjusted day change from the latest balance and prior snapshot; open risk with the unprotected count and reasons; settled/unsettled cash; positions list sorted by distance to stop with the protection state inline; "N trades need review" callout; pending proposals count fixed at 0; every number carries its as-of stamp from Balance.as_of/Position.synced_at with a stale mark when older than its cadence; empty state before the first sync; a "connect Schwab" call to action when no token exists.
- `SystemController#show` plus `update` for the manual halt toggle (reason required, audited manual_halt_set/cleared): token age vs 7 days with next Sunday marked, last sync per feed with status, sync pause reason, job failures in 7 days (SyncRun failed + Solid Queue failed executions), API spend this month (AgentRun), shadow mode indicator, accounts needing operator setup (no account_type or trading disabled) with an inline form to classify and enable them.
- `TradesController`: index (open and closed, filter needs_review), show (legs, planned vs actual stop, R), `review` form (setup, planned stop, thesis; Save / Not a trade / Skip; "N more to review"), post-mortem quick entry (one line plus followed/improvised).
- All screens mobile-responsive, server-rendered ERB with Turbo, no JS beyond Stimulus for the confirm on the halt toggle.
- Playwright via a test-only `/playwright/scenarios/:name` reseed route: healthy, expiring, expired, halted, MCP 401 page (step 8), re-auth success and failure, trade review flow.

## Instructions
You are providing an independent review. Be critical and thorough.
- Check each dashboard element against Flow 1 and the wireframes: what is shown, what is the primary number, what states exist, and whether the data model produces it (name the missing field or query)
- Check the banner rules for gaps: token missing versus expired versus revoked, sync paused for a non-token reason, a fallback calendar day, no trading account configured
- Check staleness rules: what "stale" means per number given the cadences in plan §2, and how a paused sync shows
- Check the review flow against Flow 4 and the Monarch note: what Skip means durably, what "Not a trade" does to the position's trade, how the queue is ordered, and what happens on the phone
- Check the system page against Flow 8 and §5.10: which items Phase 1 can fill, which must show "not yet" honestly, and the halt toggle's audit and confirm
- Check the account-setup path: the first login with a synced but unclassified account, and what the operator must do before anything journals
- Check the Playwright plan: whether the scenario route can be kept out of production safely, what each scenario must seed, and what the four banner states need
- Flag anything that fights a future Hotwire Native wrapper
- Be direct and opinionated; do not hedge; order by severity

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
