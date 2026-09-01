**Severity 1**

1. **Bootstrap plus sell-first will create false P&L unless the synthetic entry quantity is the pre-sale holding, not the sold quantity.**

Planned design says “sell fill with no open trade bootstraps first, quantity from the fill, then applies exit.” That is wrong for real accounts.

Sequence: legacy holding is 40 shares. First synced journalable fill is `sell 15`.

Expected trade state after the fill:

| field | expected |
|---|---|
| `status` | `open` |
| `bootstrapped` | `true` |
| `needs_review` | `true` |
| synthetic entry qty | `40`, from broker position before/around sale, not `15` |
| exit leg qty | `15` |
| remaining qty | `25` |
| `peak_quantity` | `40` |
| `avg_entry` | broker average price for the 40-share legacy position |
| `realized_pnl` | partial realized only if basis is trustworthy; otherwise nil or provisional |
| `realized_r` | nil until reviewed stop exists |

If the system bootstraps 15, it immediately closes the trade and treats the remaining 25 as a separate new bootstrapped trade on the next positions sync. That splits one lifecycle into two fake trades and corrupts setup stats, P&L, and missing-review UX.

Fix: sell-first must reconcile against the current/nearest broker position and infer pre-fill quantity as `current_position.quantity + sold_quantity` when the position still exists. If no position exists because the sale fully closed before positions sync, bootstrap quantity can equal the sell quantity, but mark basis/P&L as provisional.

2. **`journaled_at` is not a safe idempotency boundary.**

The design says unique `trade_legs.activity_id` gives idempotency and every processed activity gets `journaled_at`. That is insufficient because one activity can drive multiple durable side effects: create trade, create leg, mutate trade aggregates, mutate instrument succession, journal activity.

Crash examples:

| crash point | bad result |
|---|---|
| leg inserted, trade aggregates not recomputed | activity may be skipped if `journaled_at` was set early, leaving stale trade totals |
| trade created, leg insert fails on unique activity | duplicate open-trade rescue may attach future fills to the wrong row unless reloaded under lock |
| corporate action moves trade to new CUSIP, crashes before leg | rerun may not find the open trade on old instrument and falls back to bogus exit/entry |
| dividend leg inserted, crashes before closed trade P&L recompute | realized P&L excludes income forever if closed trade is not recalculated |

Fix: process each activity in one DB transaction with row locks on account/instrument/open trade. Insert/find the leg by `activity_id`, then recompute the affected trade from all legs, then set `journaled_at` last. Reruns should be “find existing leg and recompute,” not “skip because activity is marked.”

3. **Same-day fill ordering will be wrong if `executed_at` is missing, date-only, or broker-order granularity.**

The planned ordering is `executed_at, id`. Schwab transactions often have date-level or coarse timestamps, and the mapper already falls back from `time` to `tradeDate`. For a same-day wash, order matters.

Sequence: same instrument, same day, activities arrive out of order:

- Actual: buy 40 at 10:00, sell 40 at 15:00.
- API ingestion order: sell row first, buy row second.
- `executed_at` is date-only for both.

Expected trade row:

| field | expected |
|---|---|
| legs | entry 40, exit 40 |
| `status` | `closed` |
| `needs_review` | false if originating proposal resolves; true otherwise |
| `realized_pnl` | sell proceeds minus buy cost minus fees |
| `realized_r` | computed only if planned stop exists |

Bad planned result: sell-first bootstrap creates a fake legacy trade, then buy opens a second trade. That is catastrophically wrong.

Fix: ordering needs a broker-provided sequence if available. If not available, group same-account/same-instrument/same-day fills and solve against position deltas/orders. Where ordering cannot be proven, create/link legs but mark trade `needs_review` and exclude from setup stats until resolved.

4. **R math is underdefined and will misstate scaled trades.**

Current plan: `initial_risk = first entry quantity × (first entry price - planned_stop)`, fixed at first entry. That makes scale-ins look artificially good or bad depending on added size.

Sequence: buy 40 at 100, stop 95. Later buy 20 at 110, same stop 95. Sell all at 115.

Using first-entry risk: `40 × 5 = 200`. P&L = `40×15 + 20×5 = 700`. R = `3.5R`.

But the trade actually had capital added at risk. Total risk after scale-in is `40×5 + 20×15 = 500`. R = `1.4R`.

Expected behavior: store both concepts or choose one explicitly.

| field | recommendation |
|---|---|
| `initial_risk` | risk after the initial entry only |
| `max_risk` or `total_risk_basis` | risk added by all entry legs at their then-current planned stop |
| `realized_r` for setup stats | use total risk basis, not first-entry risk |
| `initial_realized_r` if desired | optional diagnostic using initial risk |

For setup expectancy, first-entry-only R is misleading because scaled trades become non-comparable. The review path must recompute risk from every entry leg, not just the first entry leg, especially for orphan trades reviewed after scaling or closure.

5. **Bootstrapped closed-before-review trades must not enter setup stats after review unless basis and stop timing are known.**

A bootstrapped trade can close before the user reviews it. If the user later enters setup and planned stop, the system can compute a number, but it is not the same quality as a planned trade captured at entry.

Expected:

| condition | setup stats inclusion |
|---|---|
| non-bootstrapped, planned stop known at first entry | include |
| orphan fill reviewed before exit, stop entered | include, but mark reviewed |
| bootstrapped legacy trade with synthetic entry | exclude by default |
| trade closed before stop/setup review | exclude unless user explicitly marks it valid for stats |

Otherwise the Sunday edge review will mix real strategy executions with reconstructed history.

**Severity 2**

6. **Realized P&L sign conventions need to be based on normalized leg economics, not `Activity.net_amount` directly.**

The design says `realized_pnl = exits − entries − commissions − fees + income legs`. That is correct only if entries/exits are computed from positive `quantity × price` and commissions/fees are positive. Do not mix that with signed `net_amount`.

Expected conventions:

| activity | normalized effect |
|---|---|
| buy 40 at 100, $1 fees | entry cost `4000`, fees `1`, P&L effect `-4001` |
| sell 40 at 110, $1 fees | exit proceeds `4400`, fees `1`, P&L effect `+4399` |
| dividend $12 | income `+12` |
| return of capital $20 | basis reduction, not income P&L unless trade is closed/accounting chooses otherwise |

If Schwab `net_amount` is negative for buys and positive for sells, do not also subtract fees parsed from transfer items if they are already included in net amount. Pick one accounting source. I recommend normalized gross legs plus explicit positive fee columns, with tests proving `net_amount` is not double-counted.

7. **Dividends should not blindly attach to the open trade.**

“Dividend with matching open trade creates income leg” is too broad. Real accounts can receive dividends after exit because of ex-dividend/record/payable-date timing. If the trade was open on ex-date but closed before pay date, there may be no open trade when the dividend activity arrives.

Expected behavior: attach dividend to the trade that held the shares on ex-date if available; otherwise attach by payable date only when an open trade exists and mark uncertain. The current model lacks ex-date, so payable-date matching to open trade will miss legitimate dividends and sometimes attach them to a later, unrelated lifecycle.

8. **Corporate actions cannot be represented safely as one `activity_id` per leg.**

A reverse merger replacing CUSIP A with CUSIP B in one activity needs multiple journal effects: remove/convert old shares, add new shares, possibly cash-in-lieu, ratio, and instrument succession. But `trade_legs.activity_id` is unique. That allows only one leg per Schwab activity.

Expected for reverse merger A → B:

| field | expected |
|---|---|
| original trade | same trade lifecycle continues |
| `trade.instrument_id` | moved from A to B |
| instrument B | `predecessor_instrument_id = A` |
| adjustment leg | records ratio, old quantity, new quantity, cash-in-lieu if any |
| P&L | unchanged except cash-in-lieu/fees |
| `needs_review` | true if ratio/cash components cannot be confidently parsed |

Fix: either allow multiple legs per activity with unique `(activity_id, leg_role)`, or store one corporate-action leg with structured JSON details. A single `quantity`, `ratio`, `cash_amount` row may be too thin.

9. **Split math needs exact quantity and price semantics.**

For a 2:1 split mid-trade with planned stop:

Before: buy 40 at 100, planned stop 90.

Expected after split:

| field | expected |
|---|---|
| quantity | `80` |
| `avg_entry` | `50` |
| `planned_stop` | `45` |
| `planned_target` | divided by 2 if present |
| `initial_risk` | unchanged in dollars: `40×(100−90)=400`, or recomputed equivalent `80×(50−45)=400` |
| realized P&L | unchanged at split moment |

The plan says scale quantity, avg_entry, planned_stop, target by ratio. Be precise: for a 2:1 split, quantity multiplies by 2, prices divide by 2. For a 1:10 reverse split, quantity divides by 10, prices multiply by 10. Do not multiply both quantity and prices by the same ratio.

10. **Partial fills for one order must remain separate legs but share proposal metadata.**

Sequence: one order to buy 40 partially fills as two activities: buy 25, buy 15.

Expected trade:

| field | expected |
|---|---|
| one trade | yes |
| legs | two entry legs, each linked to its own activity |
| setup/thesis/stop | copied once from `orders.order_proposal_id` |
| `avg_entry` | weighted average across both fills plus entry commissions if basis includes them |
| `peak_quantity` | `40` |
| `initial_risk` | should reflect total planned entry risk once order completes, or update as each entry fill arrives |

If initial risk is fixed after the first 25-share fill and never updated, a partially filled order that later completes will overstate R.

**Severity 3**

11. **Expected rows for ordinary scale cases need stricter definitions.**

Buy 40, sell 40:

| field | expected |
|---|---|
| legs | entry 40, exit 40 |
| `status` | `closed` |
| `peak_quantity` | `40` |
| `avg_entry` | entry price |
| `avg_exit` | exit price |
| `realized_pnl` | exit proceeds - entry cost - fees/commissions + income |
| `realized_r` | P&L / chosen risk basis |

Buy 40, buy 20, sell 30, sell 30:

| field | expected |
|---|---|
| one trade | yes |
| legs | entry 40, entry 20, exit 30, exit 30 |
| `peak_quantity` | `60` |
| `status` after first sell | `open`, qty 30 |
| `status` after second sell | `closed`, qty 0 |
| `avg_entry` | weighted average entries |
| `avg_exit` | weighted average exits |
| `realized_pnl` | all exits - all entries - fees + income |
| `realized_r` | should use total risk basis, not first-entry risk |

12. **Bootstrap quantity disagreement with later broker positions must force reconciliation, not silent recompute.**

Positions are broker-derived. If an open trade’s computed running quantity differs from the latest broker position for the same account/instrument, that is not a harmless drift.

Expected handling:

| mismatch | action |
|---|---|
| trade qty > broker qty | missing exit, transfer, corporate action, or position sync race |
| trade qty < broker qty | missing entry, transfer in, split, or bootstrap error |
| broker position absent but trade open | close only if a journaled exit/corporate action proves zero; otherwise flag |
| trade closed but broker position exists | create/reopen only through reviewed reconciliation |

Add `computed_quantity` either as a stored field or a deterministic query, and compare it to `positions.quantity` after each sync. Raise dashboard/system-health review items for mismatches.

13. **IRA/read-only account behavior must be isolated by account, but still available for wash-sale context.**

The plan says journal builder runs trading-enabled accounts only, which is correct. But the design review must explicitly preserve this:

| case | expected |
|---|---|
| same instrument held in IRA | no trade row in IRA |
| taxable trade in same instrument | taxable journal unaffected |
| IRA buy after taxable loss | future wash-sale warning/block context, not Phase 1 journal mutation |

The partial unique index includes `account_id`, so it will not collide. The risk is product-level: do not let linked-account positions satisfy taxable bootstrap reconciliation.

14. **Snapshots use the right high-level idea, but the daily return formula will break on external flows unless signs and timing are nailed down.**

PRD intent: deposits and withdrawals must not affect drawdown. The chain-linked index is right. The fragile parts are flow sign, day boundary, missing balances, and rebuild.

Expected formula if `net_flows` is positive for deposits and negative for withdrawals:

`daily_return = (ending_equity - prior_equity - net_flows) / prior_equity`

Examples:

| prior equity | ending equity | flow | expected return |
|---:|---:|---:|---:|
| 10000 | 15000 | +5000 deposit | 0% |
| 10000 | 5000 | -5000 withdrawal | 0% |
| 10000 | 9000 | 0 | -10% |

The planned formula says `equity − net_flows − prior equity`, which is correct only if withdrawals are negative. The text says deposits positive but does not explicitly say withdrawals negative in the snapshot section. Tests must lock this down.

15. **Flow day should probably use settlement date for equity reconciliation, not trade date.**

For deposits/withdrawals, drawdown should be neutralized on the day the cash hits account equity. If balance equity changes on settlement/posted date but snapshot subtracts the flow on trade date, the index gets distorted for one or more days.

Recommendation:

| field | use |
|---|---|
| `trade_date` | trading activity chronology |
| `settlement_date` or posted/effective date | external cash flow adjustment if Schwab balance reflects it then |
| `executed_at` | intraday ordering only, not daily flow bucketing unless no better date exists |

Use the date that reconciles to the balance endpoint. Add fixture tests where ACH trade date and settlement date differ.

16. **Missing balance days should not synthesize returns.**

Plan says snapshots are not written without a fresh balance, but step 6 also says latest balance on or before day close. Those conflict.

Expected:

| day | behavior |
|---|---|
| market day with fresh post-close balance | write snapshot |
| weekend/holiday | no market snapshot unless you intentionally carry display value separately |
| market day with paused sync/no fresh balance | do not write snapshot |
| late balance arrives | rebuild from that date |

Using “latest on or before” across missing days can smear a stale equity value over market days and fake zero returns.

17. **Rebuild trigger is too narrow.**

Activities sync enqueues snapshot rebuild from earliest newly seen flow date. That catches late deposits/withdrawals. It does not catch corrected balances, restated activities, changed classification from `other` to `deposit`, corporate-action cash-in-lieu, or deleted/replaced duplicate rows.

Recommendation: rebuild from earliest changed date for any balance insert/update and any cash-affecting activity create/update/reclassification, not just newly seen flows.

18. **Dashboard and EOD need fields the design does not reliably produce.**

EOD requires “journal rows created” and “rows missing post-mortems.” Dashboard requires review counts, drawdown, open risk, stale data, and unprotected count.

Missing/weak outputs:

| need | missing design detail |
|---|---|
| EOD fills recap | distinguish created today vs recomputed today |
| missing post-mortems | closed trades with no post-mortem, but probably exclude `needs_review` until accounting is resolved |
| orphan review queue | needs reason: missing setup, missing stop, bootstrap, ordering ambiguity, corporate action ambiguity |
| dashboard risk | snapshot `open_risk_amount` sums only protected positions; must surface excluded unknown risk count |
| setup stats | must exclude `needs_review`, bootstrapped-provisional, and zero/invalid-risk trades |
| audit trail | review path audits, but auto journal corrections should also produce system audit or at least sync diagnostic events |

**Concrete Alternative**

Build step 6 around a deterministic journal ledger, not direct mutation from each activity.

Minimum viable shape:

1. Add/derive `trade.current_quantity` from legs and compare to broker positions after every sync.
2. Process account+instrument journal changes under an advisory lock or row lock.
3. Treat each activity as a source event; leg insertion is idempotent, aggregate recomputation is always repeatable.
4. Set `journaled_at` only after all side effects commit.
5. Add review reasons, not one generic `needs_review`.
6. Exclude unresolved/provisional trades from setup stats.
7. Use total risk basis for expectancy R; keep first-entry risk as a separate diagnostic if desired.
8. Snapshot rebuilds must trigger from both balance changes and cash-flow activity changes.

The most important correction before implementation: do not let sell-first bootstrap, first-entry-only R, and date-only ordering ship as designed. Those three will produce wrong journal data immediately on a real account.
