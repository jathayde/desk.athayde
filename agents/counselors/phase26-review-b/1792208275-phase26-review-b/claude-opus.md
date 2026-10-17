# Phase 2.6 review, part B

I only read the files listed and wrote nothing. Findings are ordered most severe first.

## 1. Coherence

**1. The decay check picks its trades by how fast they closed (`decay_check.rb:15`, `hypothesis.rb:74`).** `since_sample` takes every trade after the sample that has *closed*, and skips the open ones. The step 4 review removed this bias from the verdict (§8, "The sample is fixed in advance"), but it is still here.
- *Scenario:* 28 named trades follow the sample and 20 have closed. Most of those 20 are quick −1R stop-outs, while the winners on trailing stops are still open. The interval's upper end falls below `expected_mean_r` two Saturdays running, and the row is flagged with a suggestion to deactivate the setup. `open_count` is stored, but it does not correct the estimate.
- *Fix:* read the longest prefix, in proposal order, in which every trade has closed (the rule `ready?` already uses at `hypothesis.rb:89-92`), and require 20 trades in that prefix.

**2. The paired head-to-head compares different claims (`calibration.rb:57`, `:82-88`).** Pairs must share `starts_on`, but not `horizon_days`. `Forecast.record!` (`forecast.rb:29`) takes each author's own horizon, as §0.2 allows.
- *Scenario:* the agent says 0.45 over 5 sessions and the operator says 0.55 over 40. Those are two events with different base rates, and `operator_minus_agent` reports the difference as skill.
- *Second problem:* `first_of_each_bet(blind.map(&:first))` at `:61` checks overlap on the agent's window only, so the operator's longer window can overlap the next pair.
- *Fix:* pair only forecasts with equal horizons. Or difference each author's skill against their own baseline instead of their raw squared errors.

**3. Names that stop trading leave the score as voids instead of misses (`resolve_forecasts_job.rb:43,49,51`, `forecast.rb:86-91`).** A history that ends counts as a failed night (`behind?`), and the fifth failed night voids the forecast as `data_unavailable`. The §0.1 rule ("miss, `ended_early`") is reached only through `instrument.delisted?`.
- *Scenario:* a watchlist name, or one from a rejected proposal, stops trading after the forecast entered. Nothing in the desk marks it delisted within five nights, so it voids. Voids are dropped before scoring (`calibration.rb:90,100`), so losers vanish and the hit rate goes up.
- *Fix:* when the threshold is reached on a `behind?` history and `detail["entered_on"]` is set, settle it as `miss` with `ended_early`, or leave it open. Never void it.

**4. "Expected R" means three different things.**
- `Forecast#expected_r` (`forecast.rb:102`) scores every miss as −1R, but an `expired` miss ends between the stop and the target.
- `Hypothesis#expected_mean_r` (`hypothesis.rb:30`) says nothing about whether it is net or gross.
- `realized_r` is net of costs.

The decay check compares net realized R with whatever was declared. An operator who copies the forecast line is comparing two different measures. *Fix:* label `expected_mean_r` as net realized R in the form and the model, and show the share of expired misses beside the expected-R line.

**5. The verdict's cache key has no version (`hypothesis.rb:127`).** The key is `[r, bar]` only, with no Stats version, seed, or draw count. Step 4 replaced the sign-flip test under the same key name, so `decide!` can freeze a stale cached result. *Fix:* add `Research::Stats::VERSION` (or the seed and draws) to the key.

**6. The audit row's `tests` can disagree with the verdict's (`hypothesis.rb:144`).** The audit logs `Hypothesis.ever_tested.count` at decision time. The frozen verdict uses the count at `completed_at` (`:124`), so the two differ whenever a hypothesis was tested in between. *Fix:* log `attributes[:evidence]["tests"]` when a verdict is present.

**7. The overlap comment is not quite true (`calibration.rb:96-100`).** It says counting the next bet "never depends on how the first ended". But voids are removed first, so when a first bet resolves as `never_entered`, the second one moves from `overlapping` to counted between snapshots. It is low impact; fix either the wording or the rule.

**What agrees:**
- The baseline follows the resolver's rules: only the stop counts on the entry day, a day touching both levels is a stop, and an expired horizon is a miss.
- `window_ends_on` (5 + horizon weekdays) is the resolver's longest path, and the extra week covers holidays.
- The Bonferroni family is fixed at `completed_at`.
- The decay check reads only trades proposed after the last sampled proposal (`:108-113`), so nothing the verdict saw leaks in.
- Stop costs and the hypothesis evidence both use the proposal's stop.
- The one mismatch with the baseline is small: it starts each path exactly at the limit. A marketable limit enters below that, so for those entries the baseline slightly overstates the chance of a hit.

## 2. Load and cost

**Per proposal:**
- One history fetch each for the reference close and volatility, the instrument's features, and SPY. All go through the shared cache.
- Then `Research::Baseline`: 2,000 paths × (horizon + 1) sessions, inside the proposal's transaction (`forecast.rb:40`), once per author. At a 60-session horizon that is about 122k simulated sessions in pure Ruby. Measure it under whatever lock that transaction holds; I could not run it.

**Skeptic at the daily cap:** 25 runs × 120,000 input tokens is 3.0M input tokens a day at worst, about 90M a month if the cap fills every calendar day. Pricing for `Agent::MODEL` is outside my files, so the cost is 3.0M × its input price per million, per day. Two seams:
- **The cap can be overrun.** The cap check at `skeptic_job.rb:25` counts and then creates, and `limits_concurrency` is keyed per proposal. Two workers for different proposals can both see 24 and both start. *Fix:* take an advisory lock, or count inside a locked row.
- **Retries are paid again.** `:15` ignores `failed` runs, so every retry of the job starts a new paid run, and it counts against the cap. Cap retries at one.

**Per night:** one 1-year history per instrument with an open forecast, so tens of calls. `ended?` → `successor` does an `Instrument.find_by` for every forecast (`:40,51-52`). That is trivial.

**Saturday:**
- Calibration: one bootstrap of 10,000 draws per cut that clears the floor (overall, 2 authors, 2 paired, plus one per setup). Seconds at most.
- Decay: an N+1. `evidence_trades` preloads `:instrument` but not `:order_proposal`, and `after_sample` reads `order_proposal.created_at` for every trade (`:111-112`). Trivial at the desk's scale.
- The 08:00 → 08:15 → 08:20 order is sound, since the decay check does not read calibration.

**Per page render:** `/research` reads the stored snapshot, but each hypothesis row calls `Hypothesis#verdict`.
- For a hypothesis under test that runs `ready?` (2–3 queries). Once the sample is ready it also runs `mean_test`: 10,000 × `min_sample` draws, up to 5M.
- The result is cached per `(r, bar)`, and `bar` changes every time the family grows, so the first render after that pays again.
- This is the one place that bends §0's "every number on a page is read from a stored row". §8 step 4 discloses it.

## 3. Plan against build

Most of the deviations are recorded in §8. The ones that are not:
- **§0.1's "miss, `ended_early`" became a void for names not marked delisted (finding 3).** §8 step 1 says an ended history counts as a failed night, but not that this turns a miss into a void.
- **`failure_digest` runs before the resolver** (`recurring.yml:49`, 17:15 against 17:20), so resolver errors reach the digest a day late. Trivial.
- **The paired cut allows different horizons (finding 2).** The plan's "authors compared only on proposals carrying both forecasts" assumes the pair is the same claim; it is not.
- **Unverified:** §0.11's audit row per calibration run lives in `CalibrationSnapshot.record!`, which is outside my files.

Matches the plan or §8: maturity, the overlap rule, Wilson quintiles, the floors, weekly clustering, the Bonferroni bar with its lower bound, the decay check's two looks and 20-trade minimum, the narrowed cost tags, the skeptic's budgets and cap, the rate-limit stop and five-night void, and the Saturday schedule.
