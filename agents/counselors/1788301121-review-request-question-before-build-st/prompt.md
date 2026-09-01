# Second Opinion Request

## Question
# Review Request

## Question
Before build step 5 (sync jobs, market calendar, tick scheduler, working-stop detection) is written, review the design against the PRD and the Schwab contract, and find what will go wrong on the first real sync and under a paused token.

## Context

### PRD and plan
- @docs/artifacts/investment-copilot-prd.md §5.2 (positions always broker-derived; instruments keyed by CUSIP), §5.3 (sync cadences, market calendar from Schwab, nothing hardcodes 9:30-16:00), §5.4.2 (working stops reconciled on every orders sync; a stop that disappears flags the position unprotected), §5.1 (all scheduled work checks token health first and degrades gracefully: queues, does not silently skip)
- @docs/phase-1-plan.md §1 rows for accounts, instruments, positions, balances, orders, activities, market_days, sync_runs; §2 (the job table, token gating, Sync::TickJob, Sync::AccountsJob, Sync::PositionsJob, Sync::OrdersJob, Sync::ActivitiesJob, Sync::CatchUpJob, Sync::MarketHoursJob); §5 (stops and open risk)
- @docs/schwab-api-contract.md (shapes, the 60-day lookback, one transaction type per call, nested orders, market hours per date, instrument lookup for missing CUSIPs)

### What exists
- Models from step 2: Account (schwab_hash, trading_enabled, account_type nullable, raw), Instrument (cusip nullable unique, schwab_instrument_id nullable unique, symbol, symbol_history, predecessor), Position (unique per account+instrument, working_stop_order_id, synced_at, raw; rows absent from the broker are to be deleted), Balance (time series), Order (broker_order_id unique per account, parent/replaces chains, order_proposal_id, placed_via), Activity (broker_activity_id unique per account, kind enum with `other` fallback, order_id, commission, fees, journaled_at), MarketDay (date unique, trading bool, session/regular open and close, source schwab|fallback), SyncRun (feed, status incl. partial and skipped_token, records_touched, unmapped_values jsonb, window_from/to), SystemSettings (sync_paused_reason).
- Step 3 adapter: @app/models/schwab/client.rb, structs @app/models/schwab/account_summary.rb @app/models/schwab/order.rb @app/models/schwab/activity.rb @app/models/schwab/market_hours.rb @app/models/schwab/instrument_ref.rb, and @app/models/schwab/fake_client.rb with fixtures under lib/schwab_fixtures/.
- Step 4: SchwabToken.usable?, Schwab.client raising NoUsableToken, Sync::CatchUpJob placeholder, recurring.yml.

### Planned step 5 design
- `Sync::Run.record(feed) { |run| ... }` wraps each feed: creates the sync_runs row, catches Schwab::Error into `failed`, counts quarantined records into `partial` with `unmapped_values`, and stamps `records_touched`, `window_from`, `window_to`.
- `MarketCalendar`: `MarketDay.for(date)` fetches through the client when missing (source schwab) and falls back to weekday-open 9:30-16:00 ET with source fallback when the token is unusable or the call fails; `MarketCalendar.session_open?(now)`, `regular_close_for(date)`. Refresh today plus 7 days from the tick.
- `Sync::TickJob` every 5 minutes: if `!SchwabToken.usable?`, write one skipped_token sync_run per hour, set sync_paused_reason, audit once per episode, return. Otherwise for each account: positions+balances if last started > 15 min ago inside the session (pre-market through post-market) or > 60 min outside; orders+activities if > 5 min inside or > 60 outside; snapshot once per market day after regular close + 20 min (step 6). Due checks use last *started* time with 1-minute slack.
- `Sync::AccountsJob` daily and after re-auth: `account_numbers` then `account(hash)` per hash; upsert by schwab_hash, keep `account_type` and `trading_enabled` as operator-set.
- `Sync::PositionsJob(account)`: `AccountSummary.from(client.account(hash))`; `Instrument.resolve(ref)` per position with the order CUSIP, schwab_instrument_id, symbol+asset_type (with an `instrument_identity_fallback` audit), then `instrument_by_symbol`; upsert positions; delete positions absent from the response; append a Balance row; then `Journal::BootstrapJob` (step 6).
- `Sync::OrdersJob(account)`: window from = max(last success − 1 day, now − 60 days); flatten nested orders with lineage; upsert by broker_order_id; a daily `status: WORKING` pass; re-fetch by id any `positions.working_stop_order` older than the window; set `placed_via` schwab_direct when no proposal matches; then recompute each position's working stop: newest working SELL stop order on the same account and instrument with a stop price, else nil.
- `Sync::ActivitiesJob(account)`: from = max(last success − 3 days, now − 60 days), one call per TRANSACTION_TYPE, upsert by broker_activity_id, map `kind` (TRADE→fill, DIVIDEND_OR_INTEREST→dividend or interest by description, ELECTRONIC_FUND/ACH/WIRE/CASH_*→deposit or withdrawal by sign, RECEIVE_AND_DELIVER→corporate_action, else other), link `order_id` by broker_order_id, resolve instrument when present; then `Journal::LinkFillsJob` (step 6).
- `Sync::CatchUpJob` after re-auth: accounts, then per account positions, orders, activities with windows widened to the pause (capped at 60 days).
- Development: Solid Queue as the Active Job adapter with the queue schema in the primary dev database, so bin/jobs runs the recurring tick locally against the fake client.

## Instructions
You are providing an independent review. Be critical and thorough.
- Check every cadence and window against §5.3 and the contract's 60-day cap and inclusive bounds; check the overlap logic cannot miss or duplicate records; check what the first-ever sync does with no prior success
- Check instrument resolution for: a position without CUSIP, a CUSIP that later appears for an instrument first seen by symbol, a ticker change, two instruments sharing a symbol (post-merger), the IRA holding the same instrument
- Check working-stop detection against §5.4.2: brackets in AWAITING_PARENT_ORDER, replaced stops, a stop cancelled out-of-band, partial fills, a stop for a larger quantity than the position, a stop older than the lookback
- Check the tick's due logic under Solid Queue drift, a slow prior run still in progress (concurrency), and the session boundary; check the fallback calendar behavior when Schwab is unreachable
- Check the activity kind mapping for cash-account realities (money-market sweeps as TRADE, interest, journal transfers) and what "other" swallows
- Check that a paused token neither grows the queue nor silently skips; check catch-up after a 3-day pause and after a 70-day pause
- Check what happens on partial failures inside a run (one account fails, one type fails) and idempotency on re-run
- Flag Phase 2 needs (reconciliation will query orders by instrument, qty, side, price, time window)
- Be direct and opinionated; do not hedge; order by severity

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
