I reviewed this read-only. One thing first: **the working tree changed while I was reviewing.** `figures` now takes a cut, `coverage` and `Research::Digest` were added, and the helpers were renamed. So the staged diff is out of date. The line numbers below are from the current working tree. Each finding also applies to the staged version unless I say it was fixed.

The two most serious problems are that the baseline flatters any forecaster, and that the paired cut stops being paired once the overlap rule runs.

## 1. Statistical defects

**1.1 The geometry baseline ignores the horizon, so it rewards anyone who quotes low numbers.** `app/models/forecast.rb:94`, used at `app/models/research/calibration.rb:76`
- `ln(E/S)/ln(T/S)` is the chance of reaching the target first if you wait forever. But the score counts a horizon that runs out as a miss (`resolution.rb:66`). It also tests only the stop on the entry day (`:58`), and counts days touching both levels as stops (`:62`).
- All three pull the real hit rate below this baseline, so the baseline's Brier score is inflated.
- **Failure scenario:** levels 47 / 50 / 56 give a baseline of 0.353. With a 10-session horizon and ~2% daily volatility, a large share of trades expire, and the real hit rate is about 0.2. A forecaster who always says 0.2 knows nothing beyond the levels and the volatility. After a few dozen forecasts the interval clears zero and the screen says "better than the levels alone".
- A smaller point in the same direction: zero drift in log prices means the price itself drifts slightly upward. A price with no expected drift gives `(E−S)/(T−S)` = 0.333 here, not 0.353.
- **Fix:** the baseline needs a volatility.
  - Option A: store σ (from the ATR(14) that step 3 adds, or the 20-day standard deviation of log returns before `starts_on`) and compute the finite-horizon, two-barrier probability. Apply the same stop-only rule on the entry day.
  - Option B, until then: change the verdict to "…than the levels alone, which ignore the horizon (this favours the forecaster)". Also show the expired share next to the hit rate, and say in the intro text (`show.html.erb:3`) that the baseline has no horizon.
- This bias comes from the plan's own §0.3 formula, so it needs a plan change, not just a code fix.

**1.2 The paired cut is not paired once the overlap rule runs.** `calibration.rb:33-35`, `:52-54`, `:63-66`
- `first_of_each_bet` runs separately for each author. The two forecasts on a proposal share their levels and `starts_on`, but not `horizon_days`, so their `checked_through` dates differ.
- **Failure scenario:**
  - Pair 1 on XYZ: the agent's forecast has a 10-session horizon and expires Oct 19; the operator's has a 5-session horizon and expires Oct 12.
  - Pair 2 starts Oct 15. The agent's forecast is dropped (Oct 15 ≤ Oct 19); the operator's is kept (Oct 15 > Oct 12).
  - Result: agent paired n=1, operator paired n=2. The "fair comparison" now compares different samples.
- **Fix:** in `paired`, apply the overlap rule per proposal before splitting by author. Drop the pair if either forecast overlaps, then build both author cuts from the surviving proposal ids.

**1.3 The bootstrap treats correlated rows as independent, so intervals are too narrow and "better" comes too early.** `stats.rb:13-18`, called at `calibration.rb:83`
- The overall and setup cuts count both authors' forecasts on one proposal. They share the outcome and the geometry and have nearly the same probability, yet each is resampled as its own observation. A desk where the operator adds a forecast to most agent entries nearly doubles n.
- Forecasts on different names in the same week also move together with the market.
- **Fix:** resample clusters, not rows. At a minimum, group by `order_proposal_id`; better, by the week of `starts_on`. Alternatively, drop the overall cut, since the author cuts already cover it and it only adds the double counting. This is a few lines: pass the group keys to `bootstrap_interval` and resample groups.

**1.4 The overlap rule only looks at resolved forecasts, so which forecast counts can change from week to week.** `calibration.rb:53-54`
- `scored` drops open forecasts before the overlap rule runs, so an earlier forecast that is still open blocks nothing.
- **Failure scenario:** F1 (30 sessions, still open) and F2 (5 sessions, starts during F1's window) are on the same name. F2 resolves and counts this Saturday. Next Saturday F1 resolves, F2 becomes "overlapping", and F1 counts instead. Each week short bets get counted first.
- **Fix:** run the overlap rule over every forecast that isn't void, with open ones blocking anything that starts inside their window so far. Then score only the kept forecasts that have resolved.

**1.5 The "counting ambiguous days as hits" range counts days the target was never reached.** Data from `resolution.rb:58`, used at `calibration.rb:74,78`
- An entry-day stop is always marked `ambiguous`, even when that day's high never got near the target. In that case it is a certain miss, not an ambiguous one.
- So `hit_rate_if_ambiguous_hit` overstates the upper end of the range.
- **Fix:** mark the entry day `ambiguous` only when `high >= target_price` as well. Otherwise keep `stopped_on_entry_day` alone. Since forecasts are frozen, this means bumping `resolver_version`, or calibration could count only rows where `detail["ambiguous"] && !detail["stopped_on_entry_day"]` and handle the entry-day case separately.

**1.6 There is no comparison of agent against operator, only each against the levels.** `calibration.rb:33-35`
- Plan §0.3 compares the authors only on proposals with both forecasts, but nothing computes that difference. The reader compares two Brier scores by eye, with no interval.
- **Fix:** on the matched pairs, compute the per-proposal difference of the operator's and agent's squared errors, with the same bootstrap (resampling by proposal). Store it on the paired rows and give it its own verdict.

**1.7 Minor points in the reliability buckets.** `calibration.rb:89-93`
- Once `RELIABILITY_FLOOR` is 50, `count` is always 5, so `BUCKET_MIN` never applies. Simpler to say "quintiles" and drop it.
- Forecasts with the same probability (people often say 0.6) can be split across a bucket boundary in an arbitrary order, giving two buckets with the same mean forecast but different observed rates. Sort by `[p, id]` so the split is explainable.

**These are fine:**
- The Wilson interval formula, including k=0 and k=n.
- The bootstrap's percentile picks (the 251st and 9750th of 10,000 sorted means) and the fixed seed.
- Bucket sizes: they differ by at most one and are at least 10.
- The hindsight Brier `h(1−h)` is the correct best constant.
- Voids and open forecasts are kept out of the score and shown in the counts.
- A pair where one forecast is void correctly drops out.
- Treating ambiguous days as misses for both the forecaster and the baseline is consistent.

## 2. Invariant breaks

- `Research::Digest#open_forecasts` (`app/models/research/digest.rb:13`) counts open forecasts every time the page or email renders. It is labelled "open now", so it is a count of rows, not a computed statistic. That's acceptable, but it sits next to Saturday's per-cut "open" figure, which will differ by a few. Either drop the live count when a snapshot exists, or keep the "now" wording, which it already has.
- `coverage` (`calibration.rb:45-48`) is computed by the Saturday job and stored, so it is fine.
- The audit: there is one `calibration_computed` row per run, written in the same transaction as the snapshots. Fine.
- Floors: `scored?` and `reliability?` hide every figure below 20 and 50, on the screen and in the email. Fine.
- Nothing reaches a prompt. Fine.

## 3. The screen and the email

- **Staleness:** the working tree's `Research::Digest#current?` fixes this for both. The Sunday run's `market_date` is Sunday (`sunday_review_job.rb:7`), so the previous Saturday counts as current and the one before shows "last computed". Fine.
- **Email author headlines:** `Digest#headlines` (`digest.rb:10`) sends both author cuts to the email next to each other, without the "not comparable" note the screen shows (`_research.text.erb:2-4`). The reader will compare them. Either email only the paired cut, or add the note.
- **Wording:**
  - "hindsight base rate 0.250" (`show.html.erb:18`) is a Brier score, not a rate. Change it to "hindsight Brier (best constant on this sample)".
  - The headline's "over 20" (`research_helper.rb:29`) should say "over 20 scored forecasts".
  - "skill against the levels +0.012" needs a short gloss, such as "lower Brier than the levels by", so the sign is clear.
- **Coverage:** the plan's "share of the operator's entries that carry a forecast" is now in the working tree (`coverage_summary`). The staged version lacked it.

## 4. Simpler versions

- Drop the overall cut. It mixes the two authors and adds the double counting in 1.3.
- Replace `BUCKET_MIN` and `MAX_BUCKETS` with fixed quintiles (1.7).
- With 1.2 fixed, building the paired cut from the proposal ids that survive the overlap rule replaces the `starts_on.uniq.one?` check and the per-author overlap rule with a single pass.
