I found 13 defects. Three of them are blocking: a malformed rule can kill the whole Saturday run, and Sunday's email can present an earlier run's numbers as this week's or quietly leave symbols out. I read the code but didn't run anything, so none of the specs were executed.

## Blocking

**1. A whole-number rule written as "3.0" crashes the Saturday job, and cash drag failing takes the correlations down with it.**
- `app/models/cash_drag_diagnostic.rb:10` does `Integer(rule.param(:weeks).to_s)` and `app/jobs/allocation/diagnostics_job.rb:16` does `Integer(rule.param(:window_days).to_s)`.
- `RiskRule#book_params_positive` (`app/models/risk_rule.rb:64-70`) accepts any positive number, so `"3.0"` or `"2.5"` saves, and then `Integer("3.0")` raises `ArgumentError`.
- `perform` (`diagnostics_job.rb:10-11`) runs cash drag first with no rescue, so the correlations never run and no `correlation_checked` row is written.
- **Fix:**
  - Add a whole-number check for `weeks` and `window_days` in `RiskRule`, or read them with `BigDecimal(...).to_i`.
  - In `perform`, wrap each of the two steps, report the error with `Rails.error.report`, and run the other step anyway.

**2. Rows from an earlier week are shown as this week's.**
- `app/models/allocation/digest.rb:6` (cash drag) and `:7` (`Correlation.latest`, which is `max(as_of)` at `correlation.rb:8`) take the newest row however old it is.
- The cash-drag line in `brief_mailer/_allocation.html.erb:7` and `_allocation.text.erb:10` doesn't print an as-of date at all.
- The "Diversifiers moving with SPY … failing for these right now" line (`:11` / `:15`) doesn't print one either.
- So if Saturday's run crashed (see #1), was discarded, or the worker was down, Sunday presents Oct 10's numbers as current.
- **Fix:**
  - Give `Digest` a date: `Digest.new(as_of: @run.market_date)` in `brief_mailer.rb:15`, and `MarketDay.today` in `system_controller.rb:8`.
  - Treat rows with `as_of < date - 6` as stale and render "not checked this week; last measured Oct 10".
  - Print `drag.as_of` on the cash-drag line.
  - Only flag diversifiers from rows that are current.

**3. Symbols that weren't measured are named on the system page but not in the email, and after a rate limit they aren't named at all.**
- The email lists only the rows that were computed. The `skipped` list lives only in the audit row, which only `system/_allocation.html.erb:5` reads.
- On `Schwab::RateLimited` (`diagnostics_job.rb:31-34`), the instruments not yet reached are never named; there is only a `"rate_limited"` key. That breaks the rule that a stale, short, or rate-limited series is named.
- With a shared 70-requests-per-minute budget, a book of more than about 70 symbols always hits this.
- **Fix:**
  - In the rescue, add each remaining instrument (`instruments.drop(index)`) to `skipped` as `symbol => "rate limited"`.
  - Have both email partials add "not measured: …" from `allocation.last_correlation_check.data["skipped"]` when the audit row's `as_of` matches the correlations'.
  - Optionally re-enqueue after `e.retry_after`. The one-year history is cached, so symbols already fetched cost nothing.

## Statistics

**4. A series that has stopped updating is correlated over old dates, without warning.**
- `closes` (`diagnostics_job.rb:40`) only rejects `history[:stale]`, which means "served from cache after a Schwab error".
- A halted or illiquid symbol whose last candle is weeks old still passes. `coefficient` then intersects dates (`correlation.rb:12`), the shared window ends weeks ago, and the result is stored as Saturday's value.
- **Fix:** in `correlate`, skip any symbol whose last close is earlier than SPY's last close, and record it in `skipped` as `"history ends <date>"`.

**5. SPY can get a correlation row of its own.**
- If SPY is held, or tagged as a diversifier, `diagnostics_job.rb:17` includes it, and the job writes a `Correlation` of 1.0 with itself.
- That breaks "SPY is the benchmark only, never a row of its own" (`correlation.rb:2`).
- **Fix:** add `.reject { it.symbol == Correlation::BENCHMARK }` on that line.

**6. One bad close kills the rest of the run.**
- `series[day] / series[prev]` (`correlation.rb:14`) raises `ZeroDivisionError` on a 0 close.
- `BigDecimal(candle[:close].to_s)` (`diagnostics_job.rb:41`) raises on a nil close.
- Only `RateLimited` is rescued, so the loop dies partway through with no audit row.
- **Fix:** in `closes`, drop candles whose close is missing or not positive. Alternatively, rescue per instrument and name the symbol in `skipped`.

**7. Splits: unverified, and I'm not asserting it.** Nothing in the repo says whether Schwab's daily `pricehistory` is split-adjusted.
- If it isn't, a 2:1 split puts a −50% return into one series and dominates a 20-day Pearson.
- **Fix:** check the adjustment against a live probe and add it to `docs/verify-on-approval.md`. If it's unadjusted, skip any series with a daily move beyond a set bound and name the date.

**8. A window longer than the history makes every symbol "short" forever.**
- One year of daily history is about 251 closes, so any `window_days` of 251 or more skips every symbol, every week.
- **Fix:** cap `window_days` in `RiskRule` validation (for example at 200).

**9. The correlation date is the job's Saturday, not the last close.**
- The email reads "20 days to Oct 17", but the last close was Fri Oct 16 (Thursday after a Friday holiday).
- Drift rows are stamped with the trading day, so the two sections disagree.
- **Fix:** print the last shared close date, or store it in a column.

**10. Two windows on the same date get mixed in the email.**
- If the job is rerun the same day after `window_days` changes, `latest` returns two rows per symbol.
- The email labels all of them with `correlations.first.window_days`.
- **Fix:** filter `Digest#correlations` to the window from the latest `correlation_checked` row.

## Weekly sampling

**11. An empty current week zeroes an ongoing cash drag.**
- At `cash_drag_diagnostic.rb:14`, `take_while` starts at week 0. If week 0 has no usable balance (a manual Monday-morning run before the sync, or a sync outage), the result is `weeks_in_cash: 0`, `cash_percent: nil`, not flagged.
- That means "counted back from the latest" isn't true: the count should start at the latest week that has a balance.
- **Fix:** use `weekly.drop_while(&:nil?).take_while { … }`, and record the starting week in `detail`.

**12. A `cash_drag_weeks` threshold above 12 can never flag.**
- `WEEKS_BACK = 12` (`cash_drag_diagnostic.rb:5`) caps the count at 12, and the rule's `weeks` has no upper bound.
- **Fix:** sample `[threshold + 1, WEEKS_BACK].max` weeks.

Time zones are fine: `Date#in_time_zone(ZONE)` gives the right New York boundaries, and the latest balance in each week wins.

## Fund flows

**13. Fund flows aren't one per week, and a future date sticks.**
- `FundFlow.record!` (`app/models/fund_flow.rb:10`) keys on the exact date entered, so Mon Oct 12 and Tue Oct 13 become two rows for the same week.
- A mistyped future date becomes `FundFlow.latest` (`:18`) for good.
- **Fix:**
  - Normalise with `as_of = as_of.to_date.beginning_of_week` in `record!`, and handle an unparseable date as a validation error.
  - Reject `as_of > MarketDay.today`.
  - Rescue `ActiveRecord::RecordNotUnique` in the controller so a double submit redirects instead of raising a 500.

## Spec gaps
- **`spec/jobs/allocation/diagnostics_job_spec.rb`:**
  - A `weeks: "3.0"` rule (#1).
  - An empty week 0 (#11), and two balances in one week where the later one wins.
  - A balance at Sun 23:30 New York, which is Monday in UTC.
  - Missing `rebalance_band` (band 0) and missing `cash_drag_weeks`.
  - SPY history stale (the path that names SPY).
  - SPY held or tagged (#5); a series that ended early (#4); a zero close (#6).
  - A rate limit after one symbol: rows kept, and the rest named (#3).
- **`spec/requests/fund_flows_spec.rb`:**
  - A stale correlation or cash-drag row in the email (#2).
  - A partial run in the email (#3).
  - The HTML part of the email, since only the text part is asserted.
  - Correlations present with no `correlation_threshold` rule.
  - Two dates in the same week, and a future date (#13).
- **System page:** `system/_allocation.html.erb` with no rows of any kind.
