# Second Opinion Request

## Question
# Review Request

## Question
Before build step 6 (the trade journal builder, setup stats, and daily snapshots) is written, review the design against the PRD and find where it will produce wrong journal data or wrong drawdown numbers on a real account.

## Context

### PRD and plan
- @docs/artifacts/investment-copilot-prd.md §5.2 (`trades`: one instrument's position lifecycle from zero back to zero; scale-ins and scale-outs as `trade_legs`; orphan fills create a trade in incomplete state with no planned stop; `setups` rolling stats; `snapshots` flow-adjusted equity), §5.3 (corporate actions and dividends adjust journal cost basis automatically), §5.7 (EOD lists rows missing post-mortems), §5.11 item 5 (fixture payloads including corporate-action and dividend events, verifying journal linking)
- @docs/artifacts/investment-copilot-ui-flows.md Flow 4 (post-trade journal entry) and the Monarch "orphan fill review" addendum
- @docs/phase-1-plan.md §4 (journal builder rules: bootstrap, link fills, leg kinds, R math, CUSIP succession, review path), §6 (snapshots: chain-linked index, per account, rebuildable, flows), §1 rows for trades, trade_legs, setups, snapshots

### What exists
- Models: Trade (status open/closed, needs_review, bootstrapped, opened_at nullable, avg_entry/avg_exit, peak_quantity, planned_stop/target, initial_risk, realized_pnl, realized_r, thesis, post_mortem, followed_setup, journal_completed_at; partial unique index: one open trade per account and instrument), TradeLeg (kind entry/exit/adjustment/income with prefix, quantity, price, ratio, cash_amount, executed_at nullable, activity_id unique where present), Activity (kind fill/sweep/dividend/interest/fee/deposit/withdrawal/transfer/corporate_action/other, status, side, quantity, price, commission, fees, net_amount, trade_date, executed_at, journaled_at, order_id → orders.order_proposal_id), Setup (stats columns), Snapshot (account, as_of unique, equity, net_flows, daily_return, index_value default 1, high_water_index default 1, drawdown fraction, open_risk_amount, open_risk_ratio, unprotected_count), Balance (time series per account), Position (#protection, #open_risk), Instrument (predecessor_instrument_id, rename!).
- Step 5 sync: activities arrive with kinds and `valid_for_journal` scope; positions carry average_price from the broker; Sync::PositionsJob and Sync::ActivitiesJob will enqueue Journal::BootstrapJob and Journal::LinkFillsJob.
- See @app/models/trade.rb @app/models/trade_leg.rb @app/models/activity.rb @app/models/snapshot.rb @app/models/position.rb @app/models/schwab/activity.rb

### Planned step 6 design
- `Journal::BootstrapJob(account)`: for each position in a trading-enabled account with no open trade, create a trade `bootstrapped: true, needs_review: true, status: open`, `avg_entry` = broker average price, `peak_quantity` = quantity, `opened_at` nil, one synthetic entry leg with no activity and no executed_at.
- `Journal::LinkFillsJob(account)`: unjournaled VALID activities in `executed_at` order, per instrument: buy fill with no open trade opens one (copying setup/thesis/planned stop from the originating proposal when `order.order_proposal_id` resolves, else `needs_review`); sell fill with no open trade bootstraps first (quantity from the fill) then applies the exit; every fill is an entry or exit leg with running quantity, avg_entry, avg_exit, peak_quantity recomputed from legs; quantity reaching zero closes the trade with realized_pnl = exits − entries − commissions − fees + income legs; `initial_risk` = first entry quantity × (entry price − planned_stop) fixed when the stop is known; realized_r = realized_pnl / initial_risk or nil. Dividend/interest with a matching open trade: income leg (feeds realized_pnl, not basis). Splits: adjustment leg with ratio, scaling quantity, avg_entry, planned_stop, planned_target. Return of capital: adjustment leg with cash_amount adjusting avg_entry. CUSIP succession (corporate_action with two securities): set predecessor_instrument_id on the new instrument and move the open trade to it with an adjustment leg; unmatched halves fall back to exit/entry with needs_review. Symbol change on a known CUSIP: rename only. Idempotent via the unique activity_id on legs; every processed activity gets journaled_at.
- Sweeps, deposits, withdrawals, transfers, fees without an instrument: journaled_at set, no leg.
- `Journal::RecomputeSetupStatsJob`: per setup, over closed trades with realized_r: win rate, avg R, expectancy (mean R), sample size; stored on `setups`.
- `Snapshots::DailyJob(account, date)`: equity = latest balance on or before the day's close; net_flows = deposits + withdrawals (+ transfers valued at net_amount) with trade_date on the day; daily_return = (equity − net_flows − prior equity) / prior equity, first snapshot return 0 and index 1; index chain-linked; high_water_index and drawdown = 1 − index / high_water; open_risk_amount and open_risk_ratio from Position#open_risk over protected positions; unprotected_count. `Snapshots::RebuildJob(account, from:)` recomputes forward; the activities sync enqueues a rebuild from the earliest newly seen flow date.
- Review path: `TradesController#review` form (setup, planned stop, thesis) clears needs_review, computes initial_risk from the first entry leg, audits `trade_reviewed`; post-mortem quick entry (one line + followed/improvised) on closed trades.

## Instructions
You are providing an independent review. Be critical and thorough.
- Walk concrete sequences and state the expected trade rows: buy 40, sell 40; buy 40, buy 20, sell 30, sell 30; sell 15 of a legacy holding of 40 on day one after bootstrap; a 2:1 split mid-trade with a planned stop; a cash dividend mid-trade; a reverse merger that replaces CUSIP A with CUSIP B in one activity; a wash of buy and sell fills on the same day out of order; a partial fill arriving as two activities for one order
- Check the R math: what initial_risk means after a scale-in, whether realized_r should use initial risk or total risk, and what the review path must recompute
- Check realized_pnl sign conventions given Activity.net_amount is signed and fees are positive
- Check bootstrapped trades: what happens when the bootstrap quantity disagrees with a later broker position, when the position closes before review, and when the same instrument is held in the IRA
- Check idempotency and re-run safety: a re-synced activity, a leg created then the job crashing, the unique open-trade index racing with two jobs
- Check the snapshot math against §5.2's intent (a deposit never resets a drawdown, a withdrawal never fakes one), the day-boundary choice (trade_date vs settlement_date vs executed_at for flows), missing balance days (weekends, holidays, paused sync), and the rebuild trigger
- Check what the EOD brief and the dashboard need from these tables that the design does not produce
- Be direct and opinionated; do not hedge; order by severity

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
