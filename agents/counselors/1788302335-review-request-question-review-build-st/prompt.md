# Second Opinion Request

## Question
# Review Request

## Question
Review build step 5 of Phase 1: the Schwab sync layer (sync-run bookkeeping, market calendar, instrument resolution, working-stop detection, the accounts/positions/orders/activities feeds, the tick scheduler, catch-up). It was built to the design you reviewed; verify the fixes hold against the code and find what will still go wrong on a real account.

## Context

### Files to Review
Uncommitted on top of the step 4 commit; `git status --porcelain` lists them.
- @app/models/sync_run.rb @app/models/market_day.rb @app/models/instrument.rb @app/models/order.rb @app/models/position.rb @app/models/activity.rb
- @app/models/schwab/activity.rb (classification moved into the adapter) @app/models/schwab/account_summary.rb @app/models/schwab/balances.rb
- @app/jobs/sync/feed_job.rb @app/jobs/sync/accounts_job.rb @app/jobs/sync/positions_job.rb @app/jobs/sync/orders_job.rb @app/jobs/sync/activities_job.rb @app/jobs/sync/tick_job.rb @app/jobs/sync/catch_up_job.rb
- @db/migrate/20260901240001_prepare_sync_columns.rb @config/recurring.yml @config/queue.yml @config/database.yml @config/environments/development.rb
- Specs: @spec/models/sync_run_spec.rb @spec/models/market_day_spec.rb @spec/models/instrument_resolve_spec.rb @spec/models/position_protection_spec.rb @spec/models/schwab/activity_kind_spec.rb @spec/jobs/sync/feeds_spec.rb @spec/jobs/sync/tick_job_spec.rb
- Supporting: @app/models/schwab/client.rb @app/models/schwab/order.rb @app/models/schwab/fake_client.rb and fixtures under lib/schwab_fixtures/

### The design it implements
- @docs/phase-1-plan.md §2 (jobs table; "Sync runs", "Instrument identity", "Activity kinds", "Market calendar" paragraphs) and §5
- Your previous design review: @agents/counselors/1788301121-review-request-question-before-build-st/codex-5.5-high.md and claude-fable.md

## Instructions
You are providing an independent review. Be critical and thorough.
- Trace the first-ever sync of an account end to end: accounts, positions (with a CUSIP-less sweep), orders (nested bracket, replacement), activities (one call per type), stop assignment. Check windows, cursors, and the gap audit against the 59-day lookback
- Check concurrency: limits_concurrency keys, the tick's due logic with a running run, two feeds resolving the same instrument at once, Instrument.resolve's retry loop (can it spin forever?)
- Check the never-null lineage rule in OrdersJob#upsert and #link_lineage, and what happens when a child arrives before its parent within one flatten
- Check working-stop selection against §5: live over awaiting, terminal of a replacement chain, partial and oversized coverage, trailing stops, a stop that fell out of the window and the re-fetch path, and what a failed or partial orders run does to existing assignments
- Check PositionsJob's delete-absent guard and the sanity check; check Balance rows and last_price derivation
- Check ActivitiesJob's per-type error handling and cursor semantics; check the kind classification against a cash account's real activity (sweeps, journals, fees, interest); check that non-VALID activities are stored but excluded from journaling
- Check the tick's token gate: no queue growth, one skipped row per hour, one audit per episode, and the pause reason being cleared only by issue!
- Check MarketDay fallback behavior and the New York "today"; check that the calendar refresh cannot abort the tick
- Check the development Solid Queue setup (queue database, connects_to) and recurring.yml entries
- Flag missing specs, and anything the isolation spec (spec/schwab_isolation_spec.rb) still cannot catch
- Be direct and opinionated; do not hedge; order by severity with file paths

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
