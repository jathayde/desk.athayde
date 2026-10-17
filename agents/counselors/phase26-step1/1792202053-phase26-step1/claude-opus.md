# Review: Phase 2.6 step 1 (forecasts and the approval quote)

Two findings block the step: **(1)** forecasts can't be recorded on days the market is closed, and **(2)** the blind add trusts whatever the browser sends. **(3)** loses the worst outcomes from the score and should be fixed in this step too. Findings 4–8 are defects to fix; 9–12 are notes. I edited nothing and ran nothing that writes. The scoring rule's core is sound; what's fine is listed at the end.

## Blocking

**1. `app/models/forecast.rb:47-48`: no forecast can be recorded on a weekend or holiday.**
The calendar stores rows for closed days with `regular_opens_at` NULL (`market_day.rb:37`, and `next_trading_day_after` creates them for each day it walks past). `find_by(...)&.regular_opens_at` then returns nil instead of falling back to 09:30, and `local < nil` raises `ArgumentError`. `Proposals::Create#record_forecast` turns that into `Refused, "forecast: comparison of ActiveSupport::TimeWithZone with nil failed"`.
- **Scenario:** on a Saturday, any agent entry is refused, because its forecast is required. The operator's form with a probability is refused too, and so is the blind add on a proposal still waiting.
- **Fix:** `day = MarketDay.find_by(date:)`. If `day && !day.trading`, return `local.to_date` (that day has no candle). Otherwise use `day&.regular_opens_at || 09:30`.
- **Spec:** `forecast_spec.rb:14` needs a closed-day row case.

**2. `forecasts_controller.rb:11`, `_forecasts.html.erb:16`, `proposals_controller.rb:22`: `saw_agent_forecast` is whatever the browser says.**
The reveal is a GET that records nothing, and the flag comes from a hidden field.
- **Scenario:** the approver opens the proposal (the form carries `0`), opens `?reveal=1` in a second tab, reads 62%, then submits from the first tab. The forecast is recorded as made blind.
- **Fix:** make the reveal a POST that writes a `forecast_revealed` audit row (or a column on the proposal). `record!` for a human then sets `saw_agent_forecast` from that record OR the param, never from the param alone.
- **Structural caveat:** `propose_order` runs only over MCP, so the agent's `probability` is a tool argument shown in the operator's own session. The form hides it on the page, not in that session. The agent may also repeat it in the thesis, which is shown on the page and in the alert. Add a line to the tool description ("do not restate the probability in the thesis") and record the caveat in §8. Step 2's paired comparison should not claim the two forecasts were independent.

**3. `resolve_forecasts_job.rb:32-34`: a delisted name Schwab no longer serves is voided, not scored.**
`candles.nil?` returns before `ended?` is checked.
- **Scenario:** a bankruptcy with no successor row. Schwab returns empty or an error, five nights of `no_data` follow, and the forecast is voided as `data_unavailable`. A forecast that entered and then went to zero leaves the sample, so the worst outcomes are the ones dropped.
- **Fix:** check `ended?(instrument)` first and settle from the stored `detail["entered_on"]`. Open verdicts already keep it through `resolve!`'s merge.
- **Spec:** `resolve_forecasts_job_spec.rb:49` only covers the case where history is still served; add the empty-history case.

## Defects to fix in this step

**4. `forecast.rb:29-33` against the migration's check at line 41: some bad inputs hit the database check instead of a clean refusal.**
`record!` checks `stop < reference_close < target`, but not `stop < entry < target` or `stop > 0`. It also rounds the probability after validating it.
- **Scenario:** limit 60, stop 47, target 56, reference 50 passes `record!`, then violates `forecasts_levels`. The same happens to `probability: 0.00004`, which rounds to `0.0000`. The error is `ActiveRecord::StatementInvalid`, which `Create` doesn't rescue: a 500 from the form and a raw exception from the tool.
- **Fix:** round first and validate the rounded value; add both level checks as `ArgumentError`.

**5. `resolution.rb:39, 55, 59`: a missing reference candle silently skips the split guard.**
With `reference` nil, `restated?` is falsy and `jumped`'s path starts at whatever candle comes first.
- **Scenario:** a delisted name read through its successor's symbol, whose series doesn't reach `reference_on`. That is exactly where a change of scale is most likely, and it is scored unchecked.
- **Fix:** with no reference candle, return `open` and let the job count a failed night. Better still, fold `restated?` and `jumped` into one "is this path on one scale" check (see item 12 below).

**6. `resolution.rb:58-61`: real crashes and spikes over 35% are voided as `split`.**
`jumped(candle)` includes the deciding candle.
- **Scenario:** entry 50, stop 47, then an earnings gap to 30 (−40%). That is a real miss, voided. The same happens to a biotech gap up through the target.
- The plan sanctions the 35% rule, but it removes the tail outcomes calibration most needs. If Schwab's history is split-adjusted, the reference check already catches splits; if not, a split shows up as a near-exact ratio.
- **Fix:** void a jump only when it lands within about 2% of a small-integer split ratio (1/2, 1/3, 2/3, 1/4, 1/5, 1/10 and their inverses). Otherwise score it. If you'd rather keep the plan's rule, add it to §7 for the user to confirm.

**7. `resolve_forecasts_job.rb:40`: `failed_nights` never resets, and one Schwab outage voids everything.**
- **Scenario A:** four bad nights scattered across a 30-session horizon, plus one more, voids a forecast whose data was mostly fine.
- **Scenario B:** Schwab's history endpoint is down for a week and every open forecast is voided at once.
- **Fix:** reset the count on a usable night. Count a night only when the failure is specific to that symbol (for example, SPY's history loaded and this one didn't), or when the night's audit row shows the run reached Schwab at all.

**8. `forecast.rb:28`, `proposals.rb:33-38`: the forecast now gates agent entries.**
`Proposals.reference` returns nil whenever `StopCollar::Candles.for` refuses: stale history, fewer than 30 candles, a last candle more than two trading days old, or any Schwab error. Since the agent's forecast is required, every agent entry is then refused. Before this step those proposals were created with their guardrails marked unavailable. The straddle rule also refuses entries whose target sits below the last close. That runs against the phase invariant ("no forecast … is an input to … the choice of what is proposed"). Name it in §8 and add it to §7.

## Notes

**9. Specs to add to `resolution_spec.rb`, matching §0.1's fixture list:**
- exact-equal touches (low = 50, low = 47, high = 56) against the `<=`/`>=` comparisons;
- a gap through the target (low and high both above 56 → `hit`, not ambiguous);
- entry on the fifth candle, and a touch on the sixth being ignored;
- `horizon_days: 1`;
- both levels touched on the horizon's last candle (an ambiguous miss, not expired);
- a non-reference candle between `reference_on` and `starts_on` that touches a level;
- unsorted input;
- a missing reference candle.

Job spec: one erroring symbol among several, a refused stale cache, a read through a successor.

**10. Immutability gaps.**
- The trigger freezes a list of columns, so any column added later to `forecasts` is editable by default. Better to freeze everything except the result columns and `updated_at`: `(to_jsonb(NEW) - ARRAY[...]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[...])`.
- `order_proposals.quote_at_approval`, `reference_close` and `reference_on` aren't frozen by the database. The audit row keeps a copy of the quote, but step 5's slippage will read the column. Add a trigger that refuses changes once they're set.
- `Forecast#resolve!` (`forecast.rb:52-56`) writes the update and the audit row outside a transaction; wrap them in one.

**11. The job, otherwise.**
- An exception on one forecast skips that instrument's remaining forecasts (the rescue is per instrument). Rescue per forecast instead.
- The job reads under the agent's `BUDGET_CEILING`, so a busy agent session can rate-limit it. That's acceptable because it waits a night, but say so.
- Rate limits (`wait: false` raises) stop the run correctly.

**12. Write the pairing caveat into the plan now, for step 2.** Agent and operator forecasts on one proposal share `reference_close` but can have different `starts_on` (agent at 09:00, operator at 11:00). The operator can also add hours later with more information under the same window. Pair only on equal `starts_on`, or show the gap in `made_at`.

## Fine as written

- **No look-ahead:** `starts_on` plus `StopCollar::Candles.final` means no candle containing range from before the forecast, and no partial bar, is ever read. The 5-minute cache (`HISTORY_FRESH`) doesn't change that for a 17:20 run.
- **Windows:** the entry window (`first(5)`), the horizon slice at `resolution.rb:45`, and the expired test at `:52` are correct. A horizon still running stays open (`:27`, `:52`), so a missing candle never becomes a miss.
- **Approval quote:** fetched outside the lock (`submit.rb:19`), only for an approver pressing on an approvable proposal. Every error, a rate limit included, becomes `unavailable` (`approval_quote.rb:14`), so it can't refuse an approval. A wrong CUSIP is recorded as unavailable, and the quote is frozen in `proposal_approved`.
- **No Schwab calls under a lock or in a render:** none in `ForecastsController` or the new partials.
- **Unattended writes:** the job writes rows only.
- **Database freeze:** the trigger covers update, delete, and truncate, and it is in `structure.sql`. `restrict_with_exception` plus the foreign key block cascade deletes. The resolver is the only writer of the outcome, and only while it's open.
- **Audit rows:** `forecast_recorded`, `forecast_resolved`, and `forecasts_checked` are written on every path, including `data_unavailable` and ended names.
- **No forecast sizes or places an order.** Nothing in the guardrails or sizing reads one; the only gating is item 8.

**Simpler (brief item 6):** little to cut. The one real candidate is merging `restated?` and `jumped` into a single same-scale check that also handles the missing reference (items 5 and 6). `failed_nights` could also be derived from `checked_through` not advancing instead of being stored in `detail`.
