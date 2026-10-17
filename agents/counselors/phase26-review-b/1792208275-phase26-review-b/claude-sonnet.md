# Phase 2.6 review, part B: seams

I read only the listed files and ran nothing. Findings are in severity order, and what is fine comes at the end.

## 1. Coherence

**1. The weekly bootstrap can fake significance.** `calibration.rb:14,36,118` with `stats.rb:14-20`.
- The Brier floor is 20 forecasts, but the interval resamples whole weeks.
- Matured forecasts arrive in bursts, so 20 or more can fall in one or two `starts_on` weeks.
- With one cluster, every draw equals the sample mean, so `[low, high]` collapses to a point and "excludes zero" is automatic. With two or three clusters the interval is nearly as narrow.
- Scenario: the first 22 matured agent forecasts all started in the same fortnight. The cell reads "distinguishable from baseline" with a zero-width interval.
- The same applies to `head_to_head` (`:84`).
- Fix: add a floor on distinct clusters, around 8 to 10 weeks, below which `skill_interval` and `operator_minus_agent_interval` are stored as "too few weeks". Store that floor with the row, as the others are.

**2. Paired cut compares unlike claims.** `calibration.rb:54-62,85`.
- The operator chooses their own `horizon_days` (plan §0.2), and the pair rule checks only `starts_on`.
- A 5-session operator forecast and a 30-session agent forecast on one proposal can resolve differently, one `expired` miss and one hit. `head_to_head` then scores the operator against an outcome their claim never made.
- The two forecasts also have different baselines and different `window_ends_on` values.
- Fix: pair only when `horizon_days` is equal, or report unequal pairs separately.
- Related: pairing on raw `starts_on` splits a Friday-evening agent forecast (starts Saturday) from a Sunday operator forecast (starts Monday), though both open on Monday's candle. Compare the first candle date instead.
- Related: the paired cut applies the overlap rule only after the maturity filter (`:57-61`). The other cuts apply it before (`:31`). A mature later pair can therefore count where the author cut counts the earlier, still-immature one.

**3. The baseline understates the entry-day stop.** `baseline.rb:10,20-21`.
- It assumes half the entry session remains after the touch.
- The resolver tests the entry candle's full low against the stop (`resolution.rb:59`).
- For the common case, a marketable limit filled at the open, the whole day is exposed.
- Result: the baseline's p(hit) is too high by roughly the first day's stop probability, which matters most for tight ATR stops.
- Fix: use 1.0 when `entry >= reference_close`, or measure the factor. Bump `Research::Baseline::VERSION`.
- Secondary: the baseline feeds close-to-close σ into a Brownian bridge that also generates the gaps, so it double-counts overnight variance. The direction is wide, not unbiased.

**4. Costs: "comparable" ignores the time gap.** `costs.rb:52-57`.
- Comparable means the same New York date plus a quote not flagged stale.
- Staleness is judged by the quote's age at fetch, not at fill.
- Scenario: the 07:03 brief proposes, the operator approves at 07:30 on a fresh pre-market quote, and the day order fills at the 09:30 open. The pre-market-to-open gap is booked as slippage and added back into `gross_r`.
- Fix: require the approval itself inside the regular session, and the first fill within a short bound of `decided_at`, such as 15 minutes. Otherwise tag it `not_comparable`.

**5. Agent forecast coverage is not measured.** `calibration.rb:47,77-79`.
- Plan §0.2 and the user's answer say a forecast is required on every agent entry.
- §8 relaxed that: unmeasurable levels leave the entry unforecast, audited as `forecast_not_recorded`.
- Only the operator's cut carries `coverage`. The agent's cut cannot show how many agent entries went unscored.
- Scenario: gap-ups past the target, which are exactly the stale-thesis entries, silently never enter calibration.
- Fix: add `coverage` for `origin: "agent"` too, with the not-recorded count.

**6. Hypothesis verdict and audit disagree on m.** `hypothesis.rb:124` against `:144`.
- The verdict's `tests` is frozen at sample completion.
- The `hypothesis_status_changed` audit row writes `tests: Hypothesis.ever_tested.count` at decision time.
- Scenario: the audit says 9 tests while the bar was computed with 4, so a reader reconciling the two sees a wrong bar.
- Fix: drop the audit row's `tests` key and rely on `verdict`, or name it `tests_now`.

**7. A `min_sample` of 10 is too small for this test.** `hypothesis.rb:31`, `stats.rb:28-34`.
- A percentile bootstrap on 10 skewed R values undercovers. The resampled means have variance (n−1)/n of the true value, and the lower bound sits at a tail quantile as small as α/m.
- A "clears" at n=10 is easier to get than the stated bar implies.
- Fix: floor at 30, or label verdicts below 30 "indicative, not a test".

**8. Acceptance never touches `expected_mean_r`, but decay judges against it.** `hypothesis.rb:130` against `decay_check.rb:22`.
- A hypothesis declared at +0.6R can be accepted at +0.1R with a positive lower bound.
- Its first decay look then reads `below` immediately.
- Look 2 contains look 1's trades (nested samples), so "two looks in a row" is close to one observation counted twice. The doc says "prompt, not test", but `flagged` and `suggestion` read as evidence.
- Fix: show at acceptance whether the sample mean is at or above the declaration. For the flag, require the second look to include at least 5 new trades, or drop the "two looks" wording.

**9. Split rule can void real crashes.** `resolution.rb:16,84,90`.
- A −33% or −50% earnings gap lands within 3% of a 3:2 or 2:1 reverse ratio.
- It is voided as `split` rather than scored, and removes the worst misses. Voids are counted, but they are not symmetric in effect.
- §7 discloses the rule, so this is low severity.
- Fix: require the reference-day price check or `Instrument` split data to corroborate, or mark such voids `possible_split` and list them.

**Cross-checks that agree:**
- **Resolver and baseline:** both-touch-counts-as-stop, the stop-only entry day, expiry as a miss, and the horizon length all match.
- **Maturity and overlap:** both use the planned window, not the outcome, so a stop-out does not change what the next bet counts as.
- **`window_ends_on`:** (5 + horizon) weekdays matches the resolver's worst case, and holidays only lengthen it.
- **Hypothesis versus decay sample:** the decay check reads trades proposed after the frozen sample's last proposal, so nothing the verdict saw leaks into it.
- **Costs signs and gross R:** the signs are right, and gross R is defined only for trades with a comparable entry.

## 2. Load and cost

**Per proposal:**
- **Baseline simulation:** `Forecast.record!` runs 2,000 paths up to 61 sessions long, once per author (`forecast.rb:40,47-50`). That is roughly 0.2 to 0.5 s of pure Ruby, and `any?` exits early on stop paths. It runs inside the proposal's transaction (§0.2), so it holds locks for that long.
  - Fix: compute the baseline before the transaction, or take it from a precomputed table keyed by (stop%, target%, σ, horizon).
  - The operator's blind add pays the same cost in a web request. That is acceptable, but note it.
- **Features snapshot:** two histories through the cache, with SPY shared.
- **Skeptic:** one enqueued run, covered below.

**Per night, 17:20 on weekdays:**
- **Schwab fetches:** one `price_history` per distinct symbol with an open forecast.
- **Open set:** every open forecast, including ones not started yet (`resolve_forecasts_job.rb:15`).
- **Rate limit:** a rate limit stops the run and leaves the rest for the next night (`:26`), without counting failed nights.
- **Ordering:** the job runs five minutes after the 17:15 failure digest. Its errors surface in the next day's digest, not that day's. Move it to 17:10 or move the digest.
- **Cache check:** `behind?` (`:49`) counts a night as failed when the cache returns a history fetched before the close, where `final` drops the partial bar. Verify the `Agent::MarketData` TTL is short enough that a 16:10 or 16:30 fetch is not served at 17:20. Otherwise failed nights accrue toward the 5-night void for no real reason.

**Per Saturday:**
- **Calibration:** ~(5 + setups) cuts, each a 10,000-draw bootstrap over weeks. That is cheap.
- **Decay:** one 10,000×n bootstrap per accepted hypothesis, and only when its trade set changed.
- **Cost:** none of these is a concern.

**Per page render:**
- **Calibration page:** reads stored rows only.
- **Hypotheses:** `verdict` runs the live bootstrap for every ready, undecided hypothesis (`hypothesis.rb:105,127`). This is the one exception to the plan's invariant that every number on a page is read from a stored row, and §8 step 4 documents it.
  - A cache miss costs 10,000×n draws, up to about 5M for n=500, which blocks a Puma thread for seconds.
  - Confirm production's `Rails.cache` is persistent, since a per-process memory store re-misses.
  - `evidence_trades` also lacks `includes(:order_proposal)`, so `after_sample`, `ready?`, and the Sunday listing issue one query per trade (`:80,111`).
  - Fix: preload `order_proposal`, and consider storing the verdict when the sample completes.

**Skeptic at the daily cap (25):**
- The ceiling is 25 runs × ≤120,000 input tokens, about 3M input tokens per day, plus output.
- At an assumed $3 per million input tokens (check `Agent::MODEL`'s price), that is about $9 a day, or $200 to $270 a month at 22 to 30 days.
- Realistic runs of 20k to 50k tokens come to a fifth to two-fifths of that.
- Real entry volume is a few a day, so a cap of 25 only guards against a runaway loop. It does not set a budget.
- The cap does not stop a run that fails and is retried on its own. `start` creates a fresh run whenever the proposal has only failed ones (`skeptic_job.rb:15`), and failed runs count toward the cap. If `ApplicationJob` retries on error, one broken proposal can spend the day's cap.
- Fix: cap per proposal at 1 retry, and tie the skeptic into the existing monthly agent budget if there is one (not visible in these files).

## 3. Plan against build

Changes recorded in §8:
- unmeasurable levels leave the entry unforecast (§0.2)
- the split-ratio rule (§0.1)
- the v2 entry-day ambiguous rule
- the Bonferroni sample fixed in advance
- the skeptic's cap and its reveal button

Gaps and drift that §8 does not say:
- **Stale plan text.** §0.2 and §7 still say the tool refuses without the forecast fields and that a refused creation writes none. §8 contradicts this. Fix the sentence in §0.2.
- **Calendar.** §0.1 says "no calendar is consulted", and §8 step 1 says "the resolver never consults the calendar". But `Resolution.call(..., closed_days:)` takes the calendar's closed days, and `ResolveForecastsJob` passes them (`:17,42`). Say so in §8.
- **Agent coverage.** §0.2 and §0.3 promise a required agent forecast, and coverage is shown only for the operator (finding 5).
- **Audit gap.** §0.11 promises one audit row per calibration run with counts. `Research::CalibrationJob` writes none itself. I can't see `CalibrationSnapshot.record!`, so check it there.
- **Gross-minus-realized.** §0.8 defines it as the cost "net of what was paid". The build adds back only comparable slippage (entry and stop), not fees, so the difference is slippage, not total cost. Rename the label.

Everything else in §0 to §7 is built as written or as §8 records it.
