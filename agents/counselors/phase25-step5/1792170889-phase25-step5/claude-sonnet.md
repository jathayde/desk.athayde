# Phase 2.5 step 5 review

I read the files you listed and did not run the specs. Findings are ordered by severity, and each has a fix.

## Wrong or misleading numbers

1. **A stale series is treated as fresh.** `diagnostics_job.rb:38-41`, `correlation.rb:12`
   - `closes` only rejects `history[:stale]`, which means "Schwab failed and the cache is old". It never checks that the last candle is recent.
   - A halted or thinly traded symbol whose last candle is weeks old still intersects SPY on old dates. It gets a correlation stored under today's `as_of`.
   - **Fix:** in the job, skip the symbol as `"last close #{date}, stale"` unless `series.keys.max >= benchmark.keys.max`. In `coefficient`, reject `dates.last < benchmark.keys.max`.

2. **A flat series is reported as too short.** `diagnostics_job.rb:28`, `correlation.rb:18`
   - `coefficient` returns nil for both "short" and "zero variance". Every nil is labelled "fewer than N shared closes".
   - A constant-NAV fund gets the wrong reason, so the audit row names a cause that isn't true.
   - **Fix:** have `coefficient` return `:flat` or raise a small error, and name it "no variance in window".

3. **A zero or nil close crashes the job.** `correlation.rb:14`, `diagnostics_job.rb:41`
   - A zero close makes `series[day] / series[prev]` raise `ZeroDivisionError`. That aborts every remaining symbol and writes no `correlation_checked` row.
   - **Fix:** in `closes`, drop non-positive closes, or rescue per symbol and name it.

4. **`window_days` below 2 is unguarded.** `diagnostics_job.rb:16`, `correlation.rb:13-15`
   - `window: 0` gives an empty `a`, so `a.sum / a.size` raises `ZeroDivisionError`. `window: 1` always yields zero variance.
   - **Fix:** `return if window < 3`, or validate it on the rule.

5. **A missing day in one series stretches both returns.** `correlation.rb:12-14`
   - Intersecting dates keeps the two series aligned, but a gap makes a multi-day return for both.
   - Dates are then no longer consecutive trading days, and the window quietly covers more calendar time.
   - **Fix:** require the shared dates to be within a few calendar days of each other, or skip with "gap in history".

6. **Splits are not handled.** `correlation.rb:14`
   - A split inside the window shows up as a roughly ±50% one-day return and dominates the Pearson sum.
   - I don't know whether Schwab's daily candles are split-adjusted.
   - **Fix:** skip a series with any |return| above about 35% as "possible split in window", or confirm adjustment from the API docs.

7. **SPY can get its own row.** `diagnostics_job.rb:17`
   - If SPY is held, or tagged as a diversifier, it is in `instruments` and gets a correlation of 1.0 with itself.
   - That breaks the "benchmark only, never a row" invariant and inflates the email's correlation list.
   - **Fix:** `.reject { |i| i.symbol == Correlation::BENCHMARK }`.

8. **`as_of` is the job date, not the data date.** `correlation.rb`, `_allocation.*:12/18`
   - The email says "20 days to Oct 17", but the last close is Friday, Oct 16.
   - If the benchmark's last candle is older, the label is further off.
   - **Fix:** store `last_close_on` on the row, add it to the migration, and print it.

## Stale rows shown as current

9. **Old correlations appear as this week's.** `digest.rb:7`, `correlation.rb:8`
   - `latest` is the global `max(as_of)`. If a Saturday run measures nothing (SPY stale, rate-limited first call, job failed), last week's rows are still "latest".
   - The "failing right now" paragraph (`_allocation.html.erb:11`, `.text.erb:15`) has no date on it.
   - Rows with a different `window_days` after a rule change also mix under one `as_of`, and the header uses only `first.window_days`.
   - **Fix:** in `Digest`, filter to the rule's current `window_days`. Compare `correlations.first.as_of` with `last_correlation_check.data["as_of"]`, and with a recency bound of about 8 days. If they differ, print "last measured <date>; this week's run measured none" and suppress the "right now" line.

10. **Cash drag has no date at all.** `digest.rb:6`, `_allocation.*:7/10`
    - The email never prints `drag.as_of`.
    - If the job stopped, for example because the `cash_drag_weeks` rule was retired and `record!` returns nil, a months-old flag reads as current.
    - **Fix:** print "as of <date>" and say "last checked <date>" when older than 8 days.

11. **The email doesn't name what was skipped.** `_allocation.*`
    - Skipped symbols and rate-limit reasons exist only on the system page.
    - The email lists the correlations that were computed and says nothing about the rest. That conflicts with "named, never guessed".
    - **Fix:** read `last_correlation_check.data["skipped"]` into the email.

12. **A rate limit names no instruments.** `diagnostics_job.rb:31-33`
    - The audit row records `"rate_limited" => message` only. Instruments not yet reached are never named.
    - **Fix:** after the rescue, add `remaining.each { skipped[symbol] = "not reached, Schwab rate limited" }`.

## Cash drag sampling

13. **The streak can end on a missing balance and read as zero.** `cash_drag_diagnostic.rb:14,16`
    - If week 0 has no usable balance, `cash_percent` is nil and `weeks` is 0. The email says "no usable balance, 0 weeks above the band".
    - A missing week in the middle also ends the streak silently, and the nil is only in `detail`.
    - **Fix:** record why the streak ended (`:below_band` or `:no_balance`, with the week). Show "unknown" instead of 0 when it ended on nil.

14. **The future leaks into week 0, and balances are taken at any hour.** `cash_drag_diagnostic.rb:24-29`
    - `all_week` runs Monday to Sunday, so a rerun for a past `as_of` sees later balances.
    - "Latest in week" can be a 06:05 Saturday sync or a mid-session balance. `Snapshot` (`snapshot.rb:35`) uses the close-to-end-of-day window instead.
    - **Fix:** cap week 0 at `as_of.end_of_day`. Prefer the last balance at or after that week's final regular close, reusing the `Snapshot` lookup.
    - The Eastern-time day boundaries themselves are correct and DST-safe.

15. **Two thresholds can fail silently.** `cash_drag_diagnostic.rb:5,10,17`
    - `WEEKS_BACK = 12`, but the rule's `weeks` has no cap. A threshold above 12 can never flag.
    - **Fix:** use `[WEEKS_BACK, threshold + 1].max`.
    - `Integer(...)` raises on `"3.0"` or `""`. That aborts `perform` before `correlate` runs (`diagnostics_job.rb:10-11`).
    - **Fix:** rescue the failure and still run `correlate`, or put the two steps in separate rescue blocks.

16. **A missing `rebalance_band` rule defaults to a 0 band.** `cash_drag_diagnostic.rb:11`
    - Any excess counts toward the streak when the rule is missing. That is plausible but undocumented, and it is not tested.

## Job and calendar

17. **A single unexpected error aborts the whole run.** `diagnostics_job.rb:42-44`
    - `closes` rescues only `Schwab::Error`. A raw `Faraday` timeout or JSON error escapes.
    - The rows computed so far remain, but no `correlation_checked` audit row is written, so the system page shows an older run.
    - **Fix:** rescue `StandardError` per symbol, report it, and name it in `skipped`.

18. **Saturday as `as_of`.** I found no direct calendar dependency, since the job doesn't call `MarketDay`.
    - A late run past midnight uses `MarketDay.today` and creates a second Sunday row for the same week.
    - **Fix:** default `as_of` to the previous Saturday when `Date.current` is a Sunday.

## Fund flows

19. **"One per week" is not enforced.** `fund_flow.rb:4,10`, `fund_flows_controller.rb:6`
    - Uniqueness is on the exact date, so Oct 12 and Oct 13 become two rows for one week.
    - A typo like 2062-10-12 also becomes `FundFlow.latest` for good.
    - **Fix:** normalize with `as_of.to_date.beginning_of_week`, and validate `as_of <= MarketDay.today`.

20. **Out-of-range amounts cause a 500.** `fund_flow.rb:5`
    - `numericality: true` accepts `1e20`. The `decimal(18,2)` column then raises `ActiveRecord::RangeError`, which the controller doesn't rescue.
    - **Fix:** add `numericality: { greater_than: -1e6, less_than: 1e6 }`.

21. **Smaller fund-flow gaps.**
    - Two concurrent saves can raise `RecordNotUnique`, which is unrescued.
    - An identical resubmit logs a "changed" audit event and resets `fetched_at`. Skip both when `amount` and `source` are unchanged.

## Crashes on missing data

22. **The system page crashes on a drift audit row without `actions`.** `system/_allocation.html.erb:4`
    - `run.data["actions"].map` fails if a drift audit row has no `actions` key.
    - The current job always sets it, but older or other rows may not.
    - **Fix:** use `Hash(run.data["actions"])`. Treat `skipped` the same way on line 5.

23. **`Digest#correlations` is fragile.** `digest.rb:7`
    - It reads `row.instrument` and `diversifier?` through `tagged?`. Confirm `tagged?` uses the preloaded `tags`, or this becomes an N+1.
    - A deleted instrument breaks the FK, so that part is safe.

## Spec gaps

- **`diagnostics_job_spec.rb:46-58`:** the title promises "keeps what it computed when Schwab runs out of budget". The test only asserts `computed => 0` on a fresh run.
  - **Add:** a rate limit that hits after SPY and XYZ succeed, with XYZ's row asserted to survive.
  - The non-sticky `enqueue` after a sticky one is also order-dependent.
- **`diagnostics_job_spec.rb:25-31`:** the fixture emits a candle for every calendar day, weekends included, with both series on the same sine wave. That hides gaps and misalignment.
  - **Add:** a series that skips a day, and an uncorrelated series.
- **Untested job cases:** stale history, SPY missing, SPY held, zero close, flat series, `window < 3`, a raw non-Schwab error, and the default `as_of` with no arguments.
- **Untested cash-drag cases:** a missing balance mid-streak, week 0 with no balance, an `unsettled_cash` mix, zero equity, a missing `cash_drag_weeks` rule, a threshold above 12, and a balance at 23:30 ET on Sunday.
- **Untested `Correlation.latest`:** two `as_of` weeks, mixed `window_days`, and a run that computed nothing after a good one.
- **`fund_flows_spec.rb`:**
  - Missing cases: a non-Monday date, a same-week duplicate, a future date, an out-of-range or non-numeric amount, a blank `as_of`, and two audit events.
  - The non-approver case only checks the count, not the response or that the form is hidden.
- **`brief_mailer_spec.rb:92`:** only the empty state is covered, and only the text part. Nothing covers the HTML partial.
  - **Add:** a case with no correlation or cash-drag rule, a nil `cash_percent`, a non-diversifier above the threshold (not flagged), and a stale-correlation week.

**Most important:** 1, 7 and 9 break stated invariants and should be fixed first. 17, 19 and 20 are the cheapest crashes to remove.
