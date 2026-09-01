**Verdict**

No. [docs/phase-1-plan.md](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:1) is broadly aligned with Phase 1, but it is not yet a faithful or complete implementation plan. The biggest problems are journal correctness, stop/open-risk semantics, token gating for scheduled runs, and several schema choices that will likely need Phase 2 rework.

**Blocking Findings**

1. **Open risk is incorrectly treated as zero in Phase 1.**  
   The plan says working stop/distance-to-stop are `nil` and open risk is `0` until stops exist in app-created proposals: [phase-1-plan.md:40](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:40), [phase-1-plan.md:82](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:82). That contradicts the PRD/UI requirement that dashboard and briefs surface distance to stop and open risk: [prd.md:141](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:141), [ui-flows.md:38](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-ui-flows.md:38).  
   Absence of a stop is not zero risk. It is unknown/unprotected risk. Phase 1 syncs Schwab orders, so it should detect broker-side stop orders where present and flag `unprotected` where absent.

2. **The journal builder cannot handle existing positions or sell-first histories.**  
   The algorithm only opens a trade when there is no open trade and a buy fill arrives: [phase-1-plan.md:100](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:100). That fails the day-one reality: the account may already hold positions, and the first synced fill may be a sell/scale-out. The PRD’s zero-to-zero lifecycle model needs a legacy/open-incomplete path for positions whose entry history predates sync. Otherwise Phase 1 will silently mis-journal real exits.

3. **`trades.status` conflates lifecycle and completeness.**  
   The plan uses `open`, `closed`, `incomplete`: [phase-1-plan.md:37](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:37). But an orphan trade can be open or closed while still incomplete. This enum will be undone in Phase 2. Use separate fields: lifecycle status (`open`/`closed`) plus completion fields such as `setup_id`, `planned_stop`, `journal_completed_at`, or `needs_review`.

4. **The quick-entry UI cannot complete incomplete trades.**  
   The plan says incomplete trades can be completed from Flow 4, but only includes post-mortem and followed/improvised: [phase-1-plan.md:116](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:116). The PRD says orphan fills need missing stop/setup captured: [prd.md:75](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:75). Add an incomplete-fill review path with setup and planned stop, matching the UI addendum’s orphan-fill review direction: [ui-flows.md:172](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-ui-flows.md:172).

5. **Scheduled work is not fully token-gated.**  
   The PRD says all scheduled work checks token health and queues/degrades rather than silently skipping: [prd.md:61](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:61). The plan only applies `TokenGated` to Schwab-touching jobs: [phase-1-plan.md:55](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:55). Morning/EOD agent runs also depend on fresh synced data and tools that may call Schwab. They need explicit gating behavior: queue, send degraded health-only email, or run against stale data with a prominent stale-data mode.

**High-Severity Design Gaps**

6. **`transactions` lacks an order link, but the journal depends on one.**  
   The journal says it copies setup/thesis/planned stop if a fill’s order maps to a proposal: [phase-1-plan.md:101](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:101). The transaction schema has no `order_id`, `broker_order_id`, or execution/order reference: [phase-1-plan.md:35](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:35). Do not rely on `raw` for this contract. Add explicit nullable linkage.

7. **`order_proposals` stores only one submission attempt.**  
   The PRD calls out ambiguous submission and reconciliation as a critical Phase 2 path: [prd.md:65](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:65). The plan flattens attempt data into one set of columns: [phase-1-plan.md:34](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:34). That will not preserve multiple attempts, reconciliation evidence, or retry history. Add a `submission_attempts` table now or explicitly model why only one attempt can ever exist.

8. **Snapshots need account scope and exact math.**  
   `snapshots.as_of` is globally unique with no `account_id`: [phase-1-plan.md:40](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:40). The app syncs taxable plus read-only linked accounts, and drawdown/open-risk may need taxable-only and whole-book views. Also specify the exact formula: `flow_adjusted_equity`, net-flow sign, first-day HWM, settlement-vs-execution date, and deposit/withdrawal classification.

9. **Market-calendar design still hardcodes a market-close workflow.**  
   The PRD says schedules derive from Schwab market hours, not hardcoded 9:30-16:00 assumptions: [prd.md:87](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:87). `Snapshots::DailyJob` is fixed at 16:20: [phase-1-plan.md:68](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:68). Make it relative to `market_days.closes_at` plus a final sync sweep.

10. **The MCP registry needs permission metadata now.**  
   Phase 1 tools are all read-only, so the plan works today: [phase-1-plan.md:78](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:78). But PRD §5.5a requires one internal tool surface with scheduled runs read-only forever: [prd.md:159](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:159). Add tool metadata like `read_only`, `interactive_allowed`, `scheduled_allowed` now so Phase 2 write tools cannot accidentally enter unattended runs.

**Scope / PRD Conflicts**

- `evaluate_hypothetical_order` omission is correct for Phase 1 because guardrails are Phase 2, but the plan contradicts itself: resolved in decision 0.5, then “pending decision 0.5”: [phase-1-plan.md:15](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:15), [phase-1-plan.md:90](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:90). Clean that up.
- The UI doc says one user: [ui-flows.md:7](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-ui-flows.md:7). The plan seeds two users: [phase-1-plan.md:13](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:13). If Whitney is real scope, add authorization policy and audit identity; otherwise remove her.
- MCP bearer token in Rails credentials conflicts with the PRD’s “Dokku config, rotatable” runtime token: [prd.md:159](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:159), [phase-1-plan.md:11](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:11). Keep operational bearer tokens in env.

**Schwab Assumptions To Mark Unverified**

- `/accounts/{hash}?fields=positions` includes balances.
- Orders can be fetched with only `fromEnteredTime`.
- Transactions endpoint shape, date window requirements, ID uniqueness, CUSIP presence, and order linkage.
- Market-hours endpoint supports “today and next 7 days” in the assumed shape.
- Corporate actions/dividends arrive with enough CUSIP and event data to adjust trades automatically.

**Bottom Line**

The plan is a strong scaffold, but not ready to build from. Fix stop/open-risk semantics, split trade lifecycle from journal completeness, add explicit transaction-order linkage, gate scheduled runs, and harden snapshot/account modeling before migrations are written.
