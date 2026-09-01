**High Severity**

1. **The halted dashboard banner is over-designed for Phase 1.**  
   Flow 1’s halted state is a rule-driven halt: rule name, trip time, reset time, exits allowed. Phase 1 only has `SystemSettings.manual_halt`, `manual_halt_reason`, and `manual_halt_at`. It cannot honestly render “daily loss tripped” or “resumes tomorrow.”  
   Action: Phase 1 banner copy must say “Paused manually” with reason/time. Defer rule-halt copy until a halt model or fields like `halt_source`, `halt_rule`, `halt_resets_at` exist.

2. **Banner precedence is missing operational states.**  
   `halted > expired > expiring > healthy` is not enough. The screen must distinguish:
   - no Schwab token yet: connect CTA
   - expired token: re-auth CTA
   - revoked token: re-auth CTA, but different cause
   - sync paused for non-token reason: show pause reason even if token is usable
   - no trading account configured: operator setup CTA
   - fallback market calendar: cadence uncertainty warning  
   Action: make banner/state derivation explicit. Do not collapse all `!SchwabToken.usable?` into “expired.”

3. **System health wants API spend before Phase 1 produces it.**  
   `AgentRun.estimated_cost` exists, but the plan says scheduled agent runs are populated in step 9. Step 7 cannot show a meaningful “API spend this month.”  
   Action: render “not yet: scheduled runs ship in step 9,” not `$0.00`, which implies real measurement.

4. **The dashboard day-change number needs a real read model/query.**  
   “Equity + flow-adjusted day change” is not just latest `Balance` plus prior `Snapshot`. Intraday, it needs net cash flows between the prior snapshot date and the current balance `as_of`.  
   Action: add a dashboard query object that returns current equity, prior snapshot, net flows since prior snapshot, day change amount, day change percent, and “no prior snapshot” state.

5. **Risk-budget UI from the Monarch note cannot ship in Phase 1.**  
   Guardrail headroom bars need active `risk_rules`, max risk per trade, daily loss limit, sector exposure, and max positions. Phase 1 explicitly has no guardrail engine and empty `risk_rules`.  
   Action: omit risk-budget cards in step 7 or label them “not yet.” Do not fake limits.

**Medium Severity**

6. **Position rows mostly have data, but need presentation rules.**  
   Phase 1 can produce symbol, quantity, cost basis, market value, last price, `protection`, `distance_to_stop`, `open_risk`, and `synced_at`. Missing or unstated:
   - `unrealized_pnl` helper/query
   - sort order when `distance_to_stop` is nil
   - grouped counts by protection state/reason
   - copy for `partial`, `oversized`, `awaiting`, `trailing_unknown`, `unprotected`  
   Action: sort protected positions by ascending distance, then unknown/unprotected states by severity.

7. **Open risk must say what it excludes.**  
   The model intentionally sums protected positions only. That is correct, but the dashboard must not imply unprotected positions are zero risk.  
   Action: render open risk as “known protected risk” plus “N excluded: partial/oversized/trailing/no stop.”

8. **Staleness rules need exact cadences per value.**  
   Use these thresholds:
   - balances/positions for trading accounts: stale after 15 min during session, 60 min off-hours
   - orders/activities: stale after 5 min during session, 60 min off-hours
   - read-only accounts: 60 min
   - quotes: 2 min
   - price history: 5 min
   - snapshots: daily close artifact, not intraday freshness  
   If sync is paused, mark broker-derived values stale regardless of age.  
   Action: centralize freshness calculation using `MarketDay`, latest successful `SyncRun`, and each row’s `as_of`/`synced_at`.

9. **`sync_paused_reason` needs a timestamp.**  
   The expired banner and health page want “sync paused Sun 6:12p.” `SystemSettings.sync_paused_reason` stores why, not when. You can infer from audit events or skipped runs, but that is brittle.  
   Action: add `sync_paused_at`, or define the query as latest `AuditEvent.sync_paused_token_expired` / first `SyncRun.skipped_token`.

10. **Trade review needs durable Skip semantics.**  
   Current `Trade#review!` and `#exclude!` cover Save and Not a trade. There is no durable Skip.  
   Action: define Skip as “leave `needs_review = true`, set `review_skipped_at`, and push behind unskipped items.” Add `review_skipped_at` if the UI has a Skip button.

11. **Review queue ordering must be explicit.**  
   `Trade::REVIEW_PRIORITY` exists, but the UI needs a query: priority order, then oldest actionable trade/fill, then id.  
   Action: implement `Trade.review_queue` with a SQL `CASE` matching `REVIEW_PRIORITY`.

12. **“Not a trade” should preserve the journal object.**  
   `exclude!` should keep the trade and legs for reconciliation, set `excluded_from_stats`, clear review, and audit distinctly. It should not delete or unlink the position lifecycle.  
   Action: use a dedicated audit payload or kind so “reviewed” and “excluded as not a trade” are distinguishable later.

**System Page**

13. Phase 1 can fill token age, next Sunday cadence, last sync per feed, sync pause reason, failed `SyncRun`/`AgentRun`, Solid Queue failures, shadow mode, and manual halt state.

14. Phase 1 cannot honestly fill API spend until step 9 agent runs exist.

15. The halt toggle must require a reason on pause and typed confirmation on unpause. Audit both with user, reason, previous reason, and timestamp.

16. Account setup must be a blocking operator path. New accounts arrive with `account_type = nil` and `trading_enabled = false`; nothing journals until the operator classifies the taxable account and enables it. Add an audit event for this change.

**Playwright**

17. The scenario reseed route must be test-only at both route and controller level. Do not expose destructive scenario seeding in development or production.

18. Four banner scenarios need these seeds:
   - healthy: usable token, recent syncs, trading account, balance, prior snapshot, positions
   - expiring: usable token with `refresh_expires_at < 24.hours.from_now`
   - expired: expired token, paused reason/time, stale balance/positions
   - halted: healthy token plus `manual_halt`, reason, timestamp

19. Add separate scenarios or request specs for no token, revoked token, no trading account, and fallback calendar. Those are more likely to regress than the happy banner states.

**Hotwire Native Risks**

20. Avoid hover-only slideovers and modal-only flows. Trade review and system halt confirmation must be normal server-rendered routes on mobile.

21. Do not make Stimulus `confirm()` the only safety mechanism for the halt toggle. A typed confirmation form will survive the future native wrapper better.

Bottom line: Step 7 should build the screens, but with honest Phase 1 data boundaries. The biggest correction is to stop rendering future guardrail/proposal/halt concepts as if the data already exists.
