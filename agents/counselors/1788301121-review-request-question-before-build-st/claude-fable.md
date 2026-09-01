Review complete. Below is the independent second opinion on the step 5 design, ordered by severity.

# Step 5 design review: sync jobs, calendar, tick, working stops

## Blocking: will go wrong on the first real sync

**1. The `to:` bound is probably date-granular, so intraday feeds run a day behind.**
The contract says a same-day transactions query needs `endDate` at 23:59:59. That is the signature of a server that truncates bounds to dates. Passing `to: Time.current` then means today's fills are excluded until tomorrow. The intraday 5-minute cadence would be pure waste. Set `to:` to the end of the current UTC day for both orders and transactions, and put "does toEnteredTime filter by timestamp or date" on the verify list. Also send `from:` at 59 days, not 60. A request that lands a few milliseconds past the cap is a 400 with no retry.

**2. `sync_runs` has no `account_id`, so per-account cursors do not exist.**
Every window in the design derives from "last success" for a feed. With a taxable account and an IRA, the last successful orders run may belong to the other account. Account A fails three times while B succeeds, and A's window silently shrinks to one day. Add a nullable `account_id` to `sync_runs` in this step's migration and compute windows per account and feed. While there, decide that `positions` runs cover balances and stop scheduling a separate `balances` feed.

**3. "Newest working SELL stop with a stop price" picks the wrong order in four common cases.**
- **Awaiting bracket child displaces the live stop.** You hold 40 shares with a WORKING stop, then place a new bracket entry for 20 more. The child sits in AWAITING_PARENT_ORDER, which is in the working set, and it is newest. The real stop on the existing lot is dropped. Prefer live statuses (WORKING, ACCEPTED, QUEUED, PENDING_ACTIVATION) over AWAITING_* when both exist.
- **Quantity is ignored.** Two stops from a scale-in, or one stop after a partial scale-out, and the risk math multiplies the full position by one stop price. Store `filled_quantity` as you already do and add `covered_quantity` on the model as remaining stop quantity. `protected?` should require coverage at or above the position quantity. Anything less shows as partially protected and counts as unprotected in the portfolio total.
- **Oversized stop is worse than no stop.** A sell stop for 40 shares when you hold 25 is a short sale on trigger in a cash account. Schwab will reject the whole order at activation. Flag a stop whose remaining quantity exceeds the position as unprotected with a distinct reason. This is a hard alert case under PRD §5.4.2.
- **Filtering on stop price in the job hides trailing stops.** `Position#protected?` already returns false when the price is nil. If the job also filters, a trailing stop and no stop look identical on the dashboard. Assign the newest live stop regardless of price and let the model decide. The UI can then say "trailing stop, price unknown".

**4. Upserts will clobber lineage and Phase 2 links.**
A replacement order can appear both nested under the REPLACED parent and as a top-level row. The top-level pass carries nil `replaces_order_id` and overwrites the nested pass. Same for `parent_order_id`, `order_proposal_id`, and `placed_via`. Once Phase 2 stamps `order_proposal_id` on a submitted order, a 5-minute sync that sets `placed_via: schwab_direct` when "no proposal matches" erases it. Rule: an upsert never nulls a lineage or proposal column that already has a value. Do lineage in a second pass mapping broker ids to local ids, since parents must exist before children reference them.

**5. Symbol fallback can bind to the wrong instrument after a merger.**
Company A is acquired and its ticker is reused by the acquirer's tracking stock. The new position arrives with CUSIP B and symbol ABC. CUSIP misses, instrument id misses, then symbol plus asset type matches the old row with CUSIP A. Every fill for the new company now lands on the old instrument. Fix: symbol fallback matches only rows whose `cusip` is NULL. Rows that carry a CUSIP are never found by symbol. Two more requirements the design omits:
- **Backfill.** When a match is found by any weaker key and the incoming ref has a CUSIP or instrument id the row lacks, write it. Never overwrite a differing one. Without this, SWVXX stays keyed by symbol forever even after Schwab sends its CUSIP.
- **Ticker change.** When a CUSIP match has a different symbol, call `rename!`. The plan says this happens in step 6, but the position sync sees it first.

## High: wrong data or noisy operations

**6. Money-market sweeps become fills, and journal transfers vanish.**
The fixture already shows a TRADE with a CASH_EQUIVALENT instrument. Mapping TRADE to `fill` will open a trade in SWVXX in step 6. Map to `fill` only when the security is EQUITY, and add `sweep` to the kind enum. JOURNAL is not junk either. A contribution moved from the taxable account into the IRA arrives as JOURNAL, and it is a withdrawal for the flow-adjusted equity series in §5.2. Map JOURNAL with a currency item to deposit or withdrawal by sign, and add `transfer` for JOURNAL or RECEIVE_AND_DELIVER with a security item, since ACAT deliveries are not corporate actions. An activity whose transfer items are all fee items is `fee`. Activities with `status` other than VALID should be stored but never journaled. There is no `status` column, so either add one or keep it in raw and filter there.

**7. Token loss mid-run is recorded as `failed`, which floods the digest.**
The refresh job can revoke the token between the tick check and a queued job's first request. `NoUsableToken`, `AuthError`, and `ReauthRequired` should finish the run as `skipped_token`, not `failed`. Only `RateLimited`, `ServerError`, `TransportError`, and `RequestError` are failures.

**8. The daily WORKING pass does not keep old GTC stops visible.**
The status filter still requires `fromEnteredTime`, and that is capped at 60 days. A GTC stop placed 61 days before the first sync is never discovered, and the position is flagged unprotected until you replace the stop. Schwab GTC orders expire at 180 days, so the blind spot is real. Two changes: probe a one-year lookback on approval since Schwabdev claims it works, and change the re-fetch rule from "older than the window" to "current working stop not present in this response". That one rule covers old stops, out-of-band cancels, and replacements whose top-level row fell outside the window. Whether the single-order endpoint returns orders older than 60 days is a verify item too.

**9. Audit flood from identity fallback.**
An `instrument_identity_fallback` audit on every resolve means one row per SWVXX position every 15 minutes, forever. Audit once, when the fallback row is created. Also handle `RecordNotUnique` in resolve with a re-lookup, because positions and activities for the same account can run on different threads and race to create the same instrument.

**10. Fallback calendar rows are never replaced.**
"Fetch when missing" treats a fallback row as present. A transport blip on Monday morning leaves Monday as a 9:30 to 16:00 weekday for good, and a holiday fallback runs intraday cadences all day. Re-fetch any row with `source: fallback` on every tick until it flips to schwab or the date passes. Compute "today" in America/New_York, not UTC, since the tick at 21:00 ET is already tomorrow in UTC. A market-hours failure must never abort the tick.

**11. Container orders cannot be inserted.**
`orders.instrument_id` is NOT NULL and an OCO container has no leg. A manual stop plus target placed as OCO at Schwab is exactly what a discretionary trader does. Skip container rows, set the children's `parent_order_id` to nil, and keep the container id in raw. Or make the column nullable now. Pick one before the fixture with a legless container lands.

## Medium: scheduling and failure semantics

**12. Due checks on "last started" double-enqueue under backlog.**
If a job is queued but has not started, the next tick sees a stale started time and enqueues again. Use Solid Queue `limits_concurrency` keyed on account and feed with `to: 1` and discard on conflict. That also covers the slow-prior-run case. Keep the 1-minute slack for cron alignment.

**13. Cursor semantics for partial and failed runs are undefined.**
If `partial` does not advance the cursor, one quarantined record pins the window until it hits 60 days and then the feed is stuck. If a `failed` run is caused by a persistent 400 on one transaction type, the same thing happens every five minutes. Decide: `partial` advances the cursor and quarantined raw records are kept and surfaced. A `RequestError` on a single type skips that type, continues, and finishes `partial`. Only 429, 5xx, and transport failures leave the cursor alone.

**14. The 70-day pause loses ten days and nobody is told.**
Windows already derive from last success, so CatchUpJob needs no special widening. What it needs is to bypass due checks, run accounts first, and run the WORKING pass. When the computed window start is later than the last success, write the gap onto the run and audit it. Step 6 should mark trades on instruments with activity near the gap as `needs_review`. Also note that a 3-day pause is entirely covered by the existing overlap logic.

**15. Delete-absent positions needs a sanity check.**
Schwab omits the `positions` key on an empty account, so an empty payload and a truncated one look the same. If `longMarketValue` is positive and positions are empty, finish `failed` and delete nothing.

**16. Cadence per account, and the transaction type list.**
The IRA is read-only for wash-sale checks. Polling it every 5 minutes across a 13-hour session is waste. Use the intraday cadences for trading-enabled accounts only and hourly for the rest. Drop MARGIN_CALL, SMA_ADJUSTMENT, and MEMORANDUM from the sync's type loop for a cash account, and verify whether omitting `types` returns everything.

**17. AccountsJob does redundant work.**
PositionsJob already calls the account endpoint every 15 minutes. AccountsJob only needs `account_numbers` to discover new hashes. On the first sync both accounts land with `trading_enabled` false and nothing journals. The health page in step 7 should show accounts that need operator setup.

## Phase 2 needs to bake in now

- Add `strategy_type` to `orders`. Reconciliation must tell a TRIGGER bracket parent from a SINGLE, and it is not a column.
- Add an index on `(account_id, instrument_id, entered_at)`. Reconciliation queries by instrument, side, quantity, price, and time window.
- The never-null-out rule in item 4 is what makes `order_proposal_id` survive the sync loop.
- Record `remaining_quantity` or derive it consistently as quantity minus filled. Item 3 needs the same number.

## Additions for docs/verify-on-approval.md

- Whether order and transaction time bounds filter by timestamp or by date.
- Whether the single-order endpoint returns orders older than the list lookback.
- Whether a replacement order appears top-level with its own `enteredTime`.
- Whether omitting `types` on transactions returns all types.
- One-year lookback on the orders list with a status filter.

**What is sound.** Per-account jobs give natural failure isolation. The overlap windows are correct given idempotent upserts. The token gate with no self-re-enqueue cannot grow the queue. The `Position` model already encodes "unknown is not zero" correctly, which is why the job should defer to it rather than pre-filter.
