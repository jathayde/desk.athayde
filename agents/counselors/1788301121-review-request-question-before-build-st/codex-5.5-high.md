**Verdict**

Do not build step 5 exactly as designed. The broad shape is right, but the first real sync will produce false unprotected states, ambiguous instrument rows, and bad cursors unless the design is tightened first.

**Highest Severity Findings**

1. **First-ever sync windows are underspecified.**
   Orders and transactions require both `from` and `to`, and transactions are inclusive ([contract](/Users/jathayde/Development/Personal/desk.athayde/docs/schwab-api-contract.md:76), [contract](/Users/jathayde/Development/Personal/desk.athayde/docs/schwab-api-contract.md:102)). “Window from = max(last success …)” does not define first sync. Use `from = now - 60.days`, `to = captured_now`, store `window_to`, and use that as the cursor basis. Never use `finished_at` as the cursor.

2. **First sync cannot discover old GTC working stops.**
   The plan says re-fetch known old stops by id ([plan](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:73)), but on first sync there are no known ids. The “daily `status=WORKING` pass” still appears constrained by required `fromEnteredTime`/`toEnteredTime` and the 60-day cap. Existing stops older than 60 days will be invisible and positions will be falsely flagged unprotected. Add a manual/import path for known open Schwab orders or verify a true open-orders endpoint/status query that bypasses entered-time lookback.

3. **Working-stop detection is too naive.**
   “Newest working SELL stop on same account/instrument with stop price” is not enough. It will mishandle bracket children in `AWAITING_PARENT_ORDER`, replaced stops, partial fills, oversized stops, and stale cancel/replace chains. Detection needs:
   `working status` per contract, replacement-chain terminal order, readable stop/activation price, sell/closing leg, same account/instrument, and `remaining_quantity >= current position quantity` or else “partially protected.”

4. **Do not clear a stop on a failed orders sync.**
   PRD requires disappeared broker stops to flag unprotected ([PRD](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:137)), but only after a complete authoritative orders check. If the orders call, one account, or one status/type fails, clearing `working_stop_order_id` creates false alarms. On partial failure, keep prior stop state and mark stop freshness degraded.

5. **Position deletion is unsafe during partial mapping.**
   Positions absent from broker should be deleted, but only after a complete per-account positions response and successful identity resolution. If one position quarantines because CUSIP/instrumentId/symbol is missing, deleting “absent” rows can erase real holdings locally. Wrap each account sync as complete-or-partial, and skip destructive deletion on partial.

6. **Instrument fallback will merge unrelated securities.**
   The fallback `symbol+asset_type` identity is dangerous for ticker reuse, post-merger symbol collisions, and instruments first seen without CUSIP. CUSIP is the intended stable key ([PRD](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:70)), but the contract says CUSIP and instrumentId are optional ([contract](/Users/jathayde/Development/Personal/desk.athayde/docs/schwab-api-contract.md:70)). Treat symbol-only instruments as provisional and `needs_review`; later CUSIP arrival should merge only under an explicit resolver that checks conflicts, open positions, orders, and activities.

7. **Paused-token behavior conflicts with “queues, does not silently skip.”**
   The plan says enqueue nothing while paused ([plan](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:60)). That is operationally better than growing Solid Queue, but it must be represented as a durable catch-up obligation, not just hourly `skipped_token` rows. Store `pause_started_at`, `pause_ended_at`, and per-feed/account catch-up gaps.

8. **Catch-up after 70 days needs an explicit data-loss state.**
   A 3-day pause can be recovered with widened windows. A 70-day pause cannot recover orders/transactions beyond Schwab’s 60-day cap ([contract](/Users/jathayde/Development/Personal/desk.athayde/docs/schwab-api-contract.md:130)). Do not pretend catch-up succeeded. Mark orders/transactions as `partial`, audit an unrecoverable gap, and require manual reconciliation/import.

9. **Tick due logic will double-enqueue under drift or slow jobs.**
   “Last started with 1-minute slack” ([plan](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:70)) does not prevent overlap. If an orders job runs longer than 5 minutes, the next tick can enqueue another orders job for the same account/feed. Add per-account/feed concurrency locks or uniqueness keys, and treat `running` syncs as not due.

10. **Market calendar fallback violates the spirit of the PRD.**
   The PRD says market hours derive from Schwab and nothing hardcodes 9:30-16:00 ([PRD](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:87)). A weekday 9:30-16:00 fallback will be wrong on holidays and early closes. Prefer last-known Schwab calendar with stale marking. If there is no Schwab-backed row, fallback may drive low-stakes cadence only, not snapshots, market-day briefs, or “regular close + 20 min” decisions.

**Medium Severity Findings**

11. **Activity cursors must be per transaction type.**
   Schwab accepts one transaction type per call ([contract](/Users/jathayde/Development/Personal/desk.athayde/docs/schwab-api-contract.md:103)). If `DIVIDEND_OR_INTEREST` succeeds and `TRADE` fails, a feed-level “last success” can either miss fills or replay everything forever. Track status/cursor by account and transaction type.

12. **`other` will hide money movement bugs.**
   Cash-account reality includes money-market sweeps, journal transfers, interest, fees, and corrections. If these collapse into `other`, snapshots and flow-adjusted drawdown become wrong. Every `other` should increment `unmapped_values` with raw `type`, `description`, `subAccount`, sign, and transfer item shape. Cash-affecting `other` should be a partial run, not a quiet success.

13. **Account sync wording is risky.**
   The plan row says `/accounts/accountNumbers` then `/accounts` ([plan](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:71)), but the contract says `/accounts` lacks `hashValue` and should not be used for linking. Step 5/adapter callers should only use `/accounts/{hash}` after `/accountNumbers`.

14. **`maxResults=3000` needs a saturation guard.**
   If orders returns exactly 3000 rows, the sync must assume truncation and split the window or fail partial. Silent success at the result cap can miss orders.

15. **Phase 2 reconciliation needs indexes now.**
   PRD reconciliation will match by instrument, qty, side, price, and time window ([PRD](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:65)). Add indexes on `orders(account_id, instrument_id, side, entered_at)`, plus price/quantity fields usable by the reconciliation query.

**Recommended Changes Before Build**

Add these design rules to step 5 before implementation:

- All cursors are account/feed/type scoped and based on captured `window_to`.
- First sync uses explicit 60-day backfill windows.
- Destructive deletes and stop clearing happen only on complete per-account runs.
- Sync jobs use per-account/feed concurrency locks.
- Symbol-only instruments are provisional and auditable.
- Old stop discovery has a real first-sync answer, not just “refetch known ids.”
- Pauses create durable catch-up gaps; pauses over 60 days create an unrecoverable-gap audit.
- Calendar fallback is stale/degraded data, not authoritative market-hours truth.
