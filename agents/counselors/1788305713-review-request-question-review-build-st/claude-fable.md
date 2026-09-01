Review complete. Findings below, ordered by severity, with the sequence walk, spec gaps, and the status of the earlier concerns at the end.

# Step 6 build review: journal builder, setup stats, snapshots

## Critical: wrong rows on a real account

**1. The split and transfer path is dead in production; the spec fabricates the input.** The mapper only sets `quantity` for TRADE activities at `app/models/schwab/activity.rb:36`. A RECEIVE_AND_DELIVER with one security item lands in the activities table with `quantity: nil`, so `link_transfer` returns at `app/models/journal/linker.rb:76` and the activity is stamped journaled with no leg. The 2:1 split spec builds the row by hand with `quantity: 40`, which the sync will never produce. The same nil zeroes out share transfers in `Snapshot.net_flows` at `app/models/snapshot.rb:43`. Direction is also wrong: `linker.rb:80` derives it from the sign of `net_amount`, which is zero on any share delivery, so an outbound ACAT or a reverse-split share removal reads as inbound. Fix: read the signed security amount from `Schwab::Activity.from(activity.raw).securities.first` the way `link_corporate_action` already does, or have the mapper populate quantity and a signed direction for non-TRADE security items. Add a spec that goes through the mapper.

**2. `reconcile_plug!` ignores adjustment legs, so every trade that has had a split, succession, or delivery gets a bogus plug on the next positions sync.** At `app/models/trade.rb:38-40` the net is entries minus exits over linked legs with no ratio applied. After the 2:1 split: legs are entry 40 and adjustment ratio 2, broker says 80, net is 40, plug becomes 40. `recompute!` then runs plug 40, entry 40, ratio 2 and stores quantity 160, flags the trade bootstrapped, and the next reconcile lands on the same 40 again. Selling 80 leaves it open at 80 forever. The succession spec passes only because ratio 0.5 makes the plug negative. Fix: replay the linked legs exactly as `recompute!` does to get the linked running quantity and the cumulative ratio, then plug = (broker − linked running) / cumulative ratio, since the plug sorts first and is scaled by every later ratio. Spec it with BootstrapJob after the split.

**3. Quantities self-heal across the positions/activities race, but the flags do not, so the review queue fills with false items every day.** Four instances of the same defect:
- `Journal::LinkFillsJob` at `app/jobs/journal/link_fills_job.rb:8-9` reconciles against whatever positions row exists. Activities sync every 5 minutes, positions every 15. A partial sell linked before the next positions sync sees the stale higher quantity and creates a plug. The plug is deleted 10 minutes later, but `bootstrapped: true`, `needs_review: true`, and `review_reason: bootstrapped` stay.
- `Journal::BootstrapJob` at `app/jobs/journal/bootstrap_job.rb:11-12` does the mirror image on every scale-in whose buy has not synced yet.
- `bootstrap_job.rb:16-19` flags `position_missing` on every normal full exit when the positions sync runs before the activities sync, because the sell is not yet an unjournaled activity. That reason outranks everything but corporate_action and ordering, and nothing clears it when the exit links and closes the trade.
- `trade.rb:44-45` calls `flag!(:bootstrapped)` on every reconcile, and `flag!` re-raises `needs_review` when it is false. A reviewed or excluded legacy holding is put back in the queue by the next BootstrapJob, every 15 minutes, until the position is closed.

Fix: gate plug creation on a non-bootstrapped trade and the `position_missing` sweep on the activities feed being caught up past the positions row, using the latest advanced activities run's `started_at` versus `position.synced_at`. Only flag when the plug is new or its quantity changed. When the plug reaches zero, clear a `bootstrapped` reason, and make `bootstrapped` mean "has a plug now" rather than "ever had one"; the linker spec at line 73 currently asserts the opposite. Clear `position_missing` in `recompute!` when the trade closes through a real exit.

**4. One exception stops journaling for the whole account permanently.** `link_all!` at `linker.rb:9` iterates chronologically with no per-activity rescue, so a failing activity aborts the loop, the job fails, and every later activity stays unjournaled on every rerun. Concrete triggers already in the code:
- A succession into an instrument whose open trade is reviewed or not bootstrapped hits the one-open-per-instrument index at `linker.rb:111`.
- `trades.create!` with a proposal already attached to an earlier trade hits the unique index on `order_proposal_id` at `linker.rb:48`. The rescue then calls `open_trade_for`, which runs inside a PostgreSQL transaction that is already aborted, so it raises `InFailedSqlTransaction`, and if it did return nil, line 31 would raise `NoMethodError`.
- `Instrument.resolve` can raise `MappingError` from `linker.rb:98-99`.

Fix: rescue per activity, flag the instrument's open trade with `corporate_action` or record the failure on a sync run, and continue. Wrap the create in `Trade.transaction(requires_new: true)` so the unique-violation rescue works.

**5. A rebuild during the session writes today's snapshot from an intraday balance, and then the real one is never built.** `Snapshots::RebuildJob` at `app/jobs/snapshots/rebuild_job.rb:7` runs through today, and `Snapshot.balance_for` at `app/models/snapshot.rb:33` falls back to the day's latest balance with no time check. A deposit dated today arriving at 10:05 triggers a rebuild from today that stores a 10:00 equity. `snapshot_due?` at `app/jobs/sync/tick_job.rb:30` then sees a row for today and never enqueues `DailyJob`. Fix: `build!` returns nil for today until close plus the delay, or the rebuild range ends at yesterday while the session is open.

## High and medium

**6. Bootstrapped trades enter setup stats with a fictional R.** `compute_initial_risk` at `trade.rb:124` only returns nil when there is no linked entry at all. A legacy holding with a plug of 40 plus a later scale-in of 20 gets `initial_quantity` 20 and a positive risk on 20 shares, while `realized_pnl` covers 60. After review it is closed, not flagged, not excluded, risk positive, and `eligible_for_stats` at `trade.rb:22` has no plug or bootstrapped test. Plan §4 said "not bootstrapped-without-stop-at-entry". Fix: initial risk is nil while a plug leg exists, and the stats scope excludes trades with a plug. Also `review!` at `trade.rb:93` always sets the stop; the plan said a closed bootstrapped trade takes setup and thesis only.

**7. Out-of-order replay was designed and not built.** `linker.rb:38-39` only flags when the late fill lands on the same open trade. A sell with the same `executed_at` as its buy and a lower id, or a sell whose buy is still PENDING in the same run, takes the legacy path: with no position, `linker.rb:52-53` prices a plug at the sale price, the trade closes with `realized_pnl` of exactly 0, and the buy then opens a second open trade the broker does not hold. No `ordering_ambiguous` flag fires because the two legs are on different trades. Fix at minimum: compute `latest` across every leg on the instrument in the account, and when a legacy sell-first trade has no position, leave `realized_pnl` nil rather than fabricating zero.

**8. `planned_stop` is mutated per link, so a re-sync of a split or succession corrupts it.** `linker.rb:84` and `linker.rb:113` divide the stop on create. `Activity#unjournal!` drops the leg, and the relink divides it again. For a succession the relink cannot even find the old trade because it already moved, so `flag_orphans` runs and the adjustment leg is never recreated. Fix: keep the stop in original-entry units and derive the displayed stop through the cumulative ratio. `compute_initial_risk` already multiplies the stop back by the factor, so the code is fighting itself.

**9. An oversold trade with no position never reconciles.** Both journal jobs iterate positions only. A plug built from a stale 40 followed by a sell of 60 leaves running −20 and no closing leg, the position row is deleted, and the trade sits open at −20 with `position_missing`. Reconciling open trades without a position against broker quantity 0 is safe: a negative plug is a no-op, so only the missing-entry case gets fixed.

**10. Snapshot flows.** `snapshot.rb:40` sums raw `net_amount`; `Activity#flow_amount` implements the type-first sign rule and is never called, so the classification fix covers `kind` but not the sign. The first snapshot's range at `snapshot.rb:39` is unbounded, so its stored `net_flows` is the lifetime sum, which the flow-adjusted day change will read. Share transfers use the position's current `last_price`, not the day's, carry no flag when unpriced, and once finding 1 is fixed a split delivery will count as an inflow of 40 shares times price and manufacture a drawdown. Exclude transfers whose adjustment leg carries a ratio.

**11. `stopped_out` and proposal adoption depend on the order row existing at link time.** `linker.rb:41` and `linker.rb:47` read `activity.order`, which is nil if the orders sync has not seen the order. The upsert re-attaches the order on the next overlap pass, but `order_id` is not in the changed-keys list at `app/jobs/sync/activities_job.rb:47`, so nothing re-evaluates. Move `stopped_out` into `recompute!` from the closing leg, and adopt a proposal in `link_fill` when the trade has none.

**12. `unjournal!` at `app/models/activity.rb:29-34` is not transactional.** A crash between `destroy!` and `update!` loses the activity from the journal for good. It also runs under the activities concurrency key, not the journal key, so it can race a running `LinkFillsJob`.

**13. Snapshot jobs have no concurrency key.** Both sync jobs enqueue `RebuildJob`, `DailyJob` is enqueued by every tick until a row exists, and `find_or_initialize_by` plus the unique index means two of them collide.

**14. Succession details.** Ratio at `linker.rb:108-110` uses `trade.quantity` rather than the out security's amount, so any journal drift changes the ratio. The `position_missing` suppression at `bootstrap_job.rb:18` keys on `activity.instrument_id`, which is whichever security came first in the payload. The fallback when one side is missing only flags; the plan said exit/entry legs.

**15. Setup stats staleness.** `review!` at `trade.rb:96` recomputes only the new setup. A trade moved from setup A to B leaves A's stored stats counting it until A happens to have another closed trade in the blanket recompute at `link_fills_job.rb:11`.

**16. Smaller deviations.** `opened_at` at `trade.rb:81` is sticky, so a late earlier fill never corrects it. Initial risk uses the first leg's price at `trade.rb:126`, not the order's average price as plan §4 says; the partial-fill spec asserts 80 where the plan gives 83. `link_fill` at `linker.rb:29` silently stamps a fill with no side; the plan said quarantine. Cash in lieu still maps to `deposit` and becomes a flow.

## Sequences, specs, and what closed

| Sequence | Code produces | Differs from expected |
|---|---|---|
| Buy 40, sell 40, fees 1 each | one closed trade, P&L 198, `missing_setup` | matches |
| 40@50, 20@52, 30@55, 30@54, stop 48 | peak 60, P&L 230, initial risk 80, total 160, R 2.875 | matches |
| Legacy sell-first, position 25 | plug 40 @ 40, exit 15, open at 25 | matches only if the positions row is post-sale; no position gives P&L 0 (item 7) |
| Bootstrap, then entry fill in window | plug deleted, quantity 40 | matches; `bootstrapped` reason persists (item 3) |
| 2:1 split via transfer | as spec'd from a hand-built row | dead path from the mapper (item 1); next bootstrap doubles it (item 2) |
| Dividend mid-trade and 10 days after | two income legs, P&L 217 | matches |
| Reverse merger A to B, bootstrapped B | trade moved, ratio 0.5, avg 100 | matches; reviewed B raises and halts the account (item 4) |
| Same-day out-of-order buy then buy | flagged, quantity 50 | matches; sell-before-buy forks silently (item 7) |
| Partial fill 25 + 15 | initial quantity 40, risk 80 | first-leg price, not average (item 16) |

`recompute!` itself is correct for ratio adjustments, income legs, and the plug sorting first. Precision, peak, average entry after a split, and the closing rule all trace clean. The per-activity transaction and `journaled_at` last are right. The shared concurrency key with `on_conflict: :discard` drops the second job rather than queuing it, which is acceptable since both are idempotent and rerun on the next sync, but note it means a bootstrap after a positions sync can be skipped for up to 15 minutes.

**Missing specs**, each of which would have caught a finding above: transfer and succession rows built through `Schwab::Activity.from` and the activities upsert; BootstrapJob after a split; LinkFillsJob against a stale positions row after a partial sell; BootstrapJob before the buy syncs; `review!` then BootstrapJob on an open legacy holding; full exit with positions ahead of activities; sell-before-buy with equal timestamps; legacy sell with no position; `unjournal!` on a split activity then relink; a plug-plus-scale-in trade reviewed and checked against `eligible_for_stats`; an exception on one activity leaving later ones linked; RebuildJob at 10:00 followed by the tick at 16:25; first-snapshot `net_flows`; a withdrawal with a positive `net_amount`; two RebuildJobs concurrently. The `rescue` at `spec/jobs/journal/hooks_spec.rb:31` should be replaced with a snapshot factory.

**Closed from the design review:** double-counted bootstrap quantity, P&L from leg cash amounts, initial quantity from the first order, nil R on non-positive risk, flows since the prior snapshot, post-close balance choice, the rebuild trigger firing, division by zero, exclusion flag, review reasons, stats triggers on review and exclude, dividends after close, succession merge, `position_missing` sweep, re-synced activity handling, stopped-out flag.

**Still open:** instrument-bearing transfers (item 1, the original item 2 in a new form), out-of-order replay (item 7), share transfer valuation and flagging (item 10), withdrawal sign from `flow_amount` (item 10), cash in lieu as a flow, nil-side quarantine, and the new class of problem this build introduced: sticky flags under the sync race (item 3).

Fix order: 3 and 2 together since they share `reconcile_plug!`, then 1, 4, 5, 6, 8. Everything else is a day of small edits.
