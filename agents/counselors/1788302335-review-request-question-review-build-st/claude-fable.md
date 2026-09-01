Files are all in hand. Writing up the review now, ordered by severity.

# Step 5 build review: sync layer

Verdict: the design fixes mostly landed, but three things will stop or corrupt sync on a real account within the first week. Fix those before commit. The rest is wrong-data and noise.

## Blocking

**1. A non-Schwab exception or a worker restart freezes a feed forever.** `SyncRun.record` at `app/models/sync_run.rb:16` rescues only `Schwab::Error`. Anything else propagates and leaves the row `status: running` with no `finished_at`. `SyncRun.due?` at `app/models/sync_run.rb:31` returns false while any running row exists, with no age bound. So one `ActiveRecord::NotNullViolation` (an order without `status`), one `RecordInvalid`, one `RecordNotUnique` on the positions index, or a dokku deploy that restarts `bin/jobs` mid-run stops that feed and account from ever being scheduled again. The tick reports nothing; the dashboard just goes stale. Deploys alone guarantee this happens. Fix: `ensure` in `record` that finishes `:failed` when the row is still running (re-raise after), and make `running?` ignore rows older than a bound (10 minutes covers the slowest feed here). Add `retry_on`/`discard_on` policy to the feed jobs so Solid Queue does not also retry a poisoned run.

**2. `Instrument.resolve` spins forever on the CUSIP-less sweep.** `app/models/instrument.rb:17-25`. Trace: positions resolve SWVXX with no CUSIP and no instrument id, miss all three lookups, `create_from` calls `lookup_cusip` and Schwab returns the fund's CUSIP, so the row is created with `cusip` set. Activities then resolve the same ref: step 3 is `where(cusip: nil, ...)` and misses because the row now has a CUSIP, `create_from` looks the CUSIP up again, `create!` raises `RecordNotUnique`, and `retry` re-enters the method with a ref that still has no CUSIP. Infinite loop on a worker thread, and because the concurrency key is held, the feed is dead. The same loop exists when `absorb` backfills an instrument id that another row already owns. The specs cannot catch it because `lib/schwab_fixtures/instruments.json` has no SWVXX, so the lookup returns nil and the provisional path runs. Fix: in `create_from`, after `lookup_cusip` returns a value, `find_by(cusip:)` before `create!` and return it through `absorb`; cap the retry at one attempt and quarantine on the second failure.

**3. One malformed record poisons a whole batch.** In `app/jobs/sync/orders_job.rb:19` the mapping runs in `perform`, outside `upsert`, so the `MappingError` rescue at line 54 is dead. One order without `orderId` or with an unparseable `enteredTime` fails every orders run for 59 days, and stop detection never runs in that window. In `app/jobs/sync/activities_job.rb:16` a bad activity aborts the rest of that type's array, the run finishes `partial`, and the cursor advances past the records that were skipped. Depending on Schwab's ordering, activities older than the bad one are lost after the 3-day overlap. Fix: map per record inside the rescue, quarantine the raw, continue.

## Wrong data on a real account

**4. A stop that Schwab will not return is never marked gone.** `refetch_missing_stops` at `app/jobs/sync/orders_job.rb:35` swallows `RequestError` and returns nothing. The local row keeps its old `WORKING` status, so `assign_working_stop!` re-picks it and the position stays protected forever. Once a GTC stop is older than the lookback and `/orders/{id}` 400s or 404s, a cancel done in the Schwab app is invisible. That is the PRD's core stop requirement failing silently. Fix: on `RequestError` set the local status to a sentinel that `working?` rejects, quarantine it, and let assignment drop it. Related: the WORKING pass at line 18 uses the 59-day lookback, so a GTC stop entered more than 59 days before first sync is still undiscoverable. Try one year first and fall back to 59 days on `RequestError`; the API verifies item 37 for you.

**5. An `AWAITING_PARENT_ORDER` child counts as protection.** `Position#protection` at `app/models/position.rb:16` accepts any working status. The preference in `assign_working_stop!` only matters when a live stop also exists. Hold 40 shares with no stop, place a 40-share bracket, and the dashboard says protected while the child is not in the market. Return a distinct unprotected reason for a stop whose status is awaiting its parent.

**6. Activity classification, `app/models/schwab/activity.rb:45`.** Three misreads:
- Any TRADE whose security is not EQUITY becomes `sweep`. The contract lists `COLLECTIVE_INVESTMENT` and `MUTUAL_FUND`, so an ETF or fund fill is filed as a sweep and never journaled. Only `CASH_EQUIVALENT` is a sweep; everything else with a security is a fill.
- A fee-only JOURNAL or CASH_DISBURSEMENT hits the type branch before `fee_only?` and becomes a `withdrawal`. Every ADR fee and wire fee then counts as a net flow in the §6 return series. Check `fee_only?` first.
- A money-market dividend on SWVXX is `dividend`, not `interest`. Harmless for the journal, wrong for reporting.

**7. Catch-up bypasses every concurrency control.** `app/jobs/sync/catch_up_job.rb:9` uses `perform_now`, so `limits_concurrency` never applies and a tick-enqueued positions run can execute alongside it. Two concurrent positions runs race on `find_or_initialize_by` and hit the unique index, which is finding 1. Enqueue the per-account jobs with `perform_later` after accounts; that bypasses the due check just as well and keeps the semaphores. Also note Solid Queue's semaphore expires after 3 minutes by default and the default conflict policy is block, not discard, so a queued duplicate runs back to back rather than being dropped. Set `on_conflict: :discard`.

**8. `pause!` can leave a stale pause reason.** `app/jobs/sync/tick_job.rb:31` is a check-then-write with no lock. `issue!` clears the reason under the settings row lock; the tick can read nil, lose the race, and write the reason after the new token is current. Sync runs, but the dashboard says paused until the next re-auth. Take the same lock and re-check `SchwabToken.usable?` inside it.

**9. Scale-ins read as partially protected.** Two 20-share bracket children on a 40-share position: assignment picks the newest, coverage is 20, `protection` says `:partial`, and the position is counted unprotected. This is the normal shape of a scaled-in position. Sum remaining quantity across live candidates for coverage and open risk, keep the newest as the display stop.

**10. Smaller wrong-data items.**
- `working_pass_today?` at `orders_job.rb:32` uses `count > 1`; the current run is not counted, so the pass fires on the first two runs of the day.
- `orders.uniq(&:order_id)` keeps the first occurrence, which is the older snapshot when the WORKING pass returns a fresher state.
- `link_lineage` at `orders_job.rb:60` only indexes rows in this batch. A child first seen alone never links to a parent that already exists in the table. Index by every referenced id.
- Zero-quantity positions are stored and count as unprotected. Treat them as absent.
- The `other` quarantine and the gap audit fire on every run for as long as the record or stale cursor sits in the window: partial runs for 59 days and an audit row per run. Quarantine on `new_record?` only, and audit the gap once per `gap_from`.
- Stop assignment runs on partial runs; the plan says complete runs only. The re-fetch path makes partial safe, so update the plan rather than the code, but decide.
- `max_by(&:entered_at)` raises when any candidate has a nil `entered_at`.

## Specs, isolation, and what holds

**Missing specs.** A non-Schwab exception inside `record`. A stale running row and the tick. The resolve collision after a successful CUSIP lookup (add SWVXX to `instruments.json` and the feeds spec hangs today). A bad order and a bad activity mid-batch. Refetch 404 clearing a stop. Awaiting-child protection. Scale-in coverage. ETF and fee-only classification. Working pass count. Catch-up overlapping a tick. The pause and issue race.

**What the isolation spec cannot catch.** Schwab enum values now live outside the namespace and are not in its list: `Order::LIVE_STATUSES` and `sells` in `app/models/order.rb`, `"VALID"` in `app/models/activity.rb:14`, `status: "WORKING"` in `orders_job.rb:18`, and `dig("cusip")` in `instrument.rb:35`, which reads a raw Market Data body without a mapper. Move each behind a `Schwab::` constant or mapper and add `WORKING`, `VALID`, and `SELL` to the spec's list.

**Environment.** The development queue database and `connects_to` are correct. `recurring.yml` schedules `AccountsJob` directly, which contradicts the plan's "only the tick is scheduled" rule but is harmless since `record` turns token loss into one skipped row a day. `docs/verify-on-approval.md` has the step 5 section pasted twice. Test env has no `queue_adapter`, so `issue!` enqueues `CatchUpJob` on the async adapter during controller specs; set it to `:test`.

**What holds.** Per-account cursors, the 59-day floor with end-of-UTC-day `to`, and the gap audit are correct. Lineage is never nulled and survives a top-level replacement. The calendar fallback re-fetches until Schwab answers, New York "today" is right, and a market-hours failure cannot abort the tick. Token loss lands as `skipped_token`. Delete-absent is correctly gated on a complete run and the empty-positions sanity check.
