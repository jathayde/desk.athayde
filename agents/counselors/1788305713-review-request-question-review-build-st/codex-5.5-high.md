**Critical Findings**

1. [app/models/schwab/activity.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/activity.rb:36) leaves `quantity` nil for non-TRADE activities, so real split/ACAT transfer rows will be stamped journaled with no leg.
`Journal::Linker#link_transfer` requires `activity.quantity` ([linker.rb:76](/Users/jathayde/Development/Personal/desk.athayde/app/models/journal/linker.rb:76)), but the mapper only sets quantity for trades. The split spec bypasses the mapper by hand-building an activity with quantity, so it proves the wrong path. Result: 2:1 split still produces wrong journal quantity and later sells can drive the trade negative.

2. [app/models/snapshot.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/snapshot.rb:40) sums raw `net_amount` for deposits/withdrawals instead of normalized `Activity#flow_amount`.
The mapper classifies withdrawals by type first, but snapshot math still trusts Schwab’s sign. If an outbound type arrives positive, drawdown treats the withdrawal as a deposit. The correct helper exists at [activity.rb:23](/Users/jathayde/Development/Personal/desk.athayde/app/models/activity.rb:23) and is unused. The snapshot spec only covers negative withdrawals, so it misses this.

3. Same-day out-of-order sell/buy is still broken.
Activities sort by `executed_at, id` ([activity.rb:15](/Users/jathayde/Development/Personal/desk.athayde/app/models/activity.rb:15)), and ambiguity is flagged only when a new leg is strictly earlier than the latest existing leg ([linker.rb:38](/Users/jathayde/Development/Personal/desk.athayde/app/models/journal/linker.rb:38)). Equal date-only timestamps are not flagged. A sell row ingested before a same-day buy still creates a fake bootstrapped closed trade, then the buy opens a second trade.

4. Sell exceeding the current journal quantity is not handled.
`Trade#recompute!` allows running quantity to go negative and leaves the trade open with nonsense aggregates ([trade.rb:64](/Users/jathayde/Development/Personal/desk.athayde/app/models/trade.rb:64), [trade.rb:77](/Users/jathayde/Development/Personal/desk.athayde/app/models/trade.rb:77)). This will happen on missing exits/transfers, stale positions, or bad ordering. It should split/flag/quarantine, not produce an open trade with negative quantity.

5. Transfer flow drawdown is still wrong.
Even if transfer quantity were populated, [snapshot.rb:41](/Users/jathayde/Development/Personal/desk.athayde/app/models/snapshot.rb:41) values share transfers using the current position price and `net_amount` sign. Real share transfers often have zero cash amount, so direction is ambiguous, and rebuilds can change historical returns as current prices change.

**Major Findings**

6. Initial risk is wrong for partial fills with different prices.
`initial_quantity_from` groups same-order fills, but `compute_initial_risk` uses only the first fill’s price ([trade.rb:124](/Users/jathayde/Development/Personal/desk.athayde/app/models/trade.rb:124)). A 25-share fill at 50 plus 15 at 50.20 should use weighted average initial entry price, not 50 for all 40 shares. The existing spec uses nearly this case but asserts the incorrect `80`.

7. The orphan fallback for initial quantity does not match the design.
The design says fallback to all entries before the first exit. Code falls back to `[first_fill]` when there is no broker order id ([trade.rb:111](/Users/jathayde/Development/Personal/desk.athayde/app/models/trade.rb:111)). Orphan partial fills without order linkage will understate risk and overstate R.

8. Closed-before-review trades can pollute setup stats.
`review!` computes risk and clears review on any trade ([trade.rb:92](/Users/jathayde/Development/Personal/desk.athayde/app/models/trade.rb:92)); `eligible_for_stats` only checks closed/reviewed/not excluded/positive risk ([trade.rb:22](/Users/jathayde/Development/Personal/desk.athayde/app/models/trade.rb:22)). There is no “stop known before exit” marker. Post-hoc stops on already-closed orphan trades can become stats-eligible.

9. Fill quarantine is missing in the linker.
`link_fill` returns on nil instrument/side/quantity ([linker.rb:29](/Users/jathayde/Development/Personal/desk.athayde/app/models/journal/linker.rb:29)), but `link!` still stamps `journaled_at` ([linker.rb:21](/Users/jathayde/Development/Personal/desk.athayde/app/models/journal/linker.rb:21)). That silently loses fills instead of quarantining them.

10. Corporate-action fallback is too weak.
If one side of succession is missing, `flag_orphans` only flags open trades it can resolve ([linker.rb:119](/Users/jathayde/Development/Personal/desk.athayde/app/models/journal/linker.rb:119)), then the activity is stamped journaled. It does not create fallback exit/entry rows, preserve the unresolved payload for review, or prevent one-sided corporate actions from disappearing.

11. `stopped_out` can become stale.
It is set after a stop exit closes a trade ([linker.rb:41](/Users/jathayde/Development/Personal/desk.athayde/app/models/journal/linker.rb:41)), but `recompute!` never recalculates or clears it. If the stop fill is corrected/invalidated and `unjournal!` removes the leg, the trade can remain marked stopped out.

**Concerns Closed**

The plug-leg design is mostly present: `reconcile_plug!` exists, plug legs sort first, the link job has a second reconcile pass, and bootstrap/link share the `"journal-#{account.id}"` concurrency key. P&L from leg `cash_amount` is also the right direction, and setup stats now exclude `needs_review`, `excluded_from_stats`, and non-positive risk.

**Missing Specs**

Add specs for mapper-produced split/transfer rows, positive-signed withdrawals, same-day sell-before-buy with equal timestamps, sell exceeding plug/current quantity, orphan partial fills with no order id, post-hoc review after close, one-sided corporate action fallback, invalidated stop fills clearing `stopped_out`, and share-transfer snapshot rebuilds.

I attempted the targeted specs, but the local Ruby environment cannot run them: Bundler `4.0.4` from `Gemfile.lock` is not installed.
