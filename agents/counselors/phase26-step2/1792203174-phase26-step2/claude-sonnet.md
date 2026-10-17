I've read the plan, both model files, the `Forecast` model, the snapshot and job, the screen, the helper and the email partials, and I haven't run or edited anything. `Bash` is disabled here, so I read the working-tree files instead of `git diff --cached`. The staged state matches them per the git status. I did not read the specs. Findings, most severe first:

## Findings

**1. The scored sample is cut off on the right, which flatters high-probability forecasters.**
- Location: `calibration.rb:35`, `scored?` at line 32.
- Only resolved forecasts are scored, and hits and stop-outs resolve early. Expiries, which are misses, resolve only when the full horizon has run.
- Take a Saturday snapshot with a 20-session horizon. Forecasts from the last few weeks enter the score only if they already hit or stopped. Those still open will mostly end as `expired` misses.
- So recent cohorts look better than they will. The same forecasts' contribution also changes at the next snapshot, so history is not reproducible from the rows.
- The `open` count is displayed, but nothing excludes the bias.
- Fix: score only forecasts whose window has fully elapsed. Use a stored `latest_possible_on` or an approximation, `starts_on + (entry_window + horizon_days) × 7/5 days < as_of`. Report the rest as `open`.
- The same cutoff fixes finding 5's retroactive drop (an overlapping later forecast counted now, then dropped once the earlier one resolves).

**2. The geometry baseline ignores the horizon, so it is too high and flatters forecasters who shade down.**
- Location: `forecast.rb:94`, used at `calibration.rb:54`.
- The formula itself is correct for the infinite-horizon driftless case: `(x−a)/(b−a)` in log prices.
- But the claim is scored with three conservative rules: expiry is a miss, the target is untested on the entry candle, and a day touching both levels counts as the stop.
- Example: 5% target, 5% stop, 1.5% daily σ, 10-session horizon. The baseline says about 0.50, but the realised rate is nearer 0.35–0.40.
- A forecaster who always says 0.40 then beats "the levels alone" by Brier without any skill. The "better than the levels alone" verdict can therefore be false.
- Fix: make the baseline finite-horizon. Step 3's ATR (as a fraction of close) is already planned, and it can feed a σ stored on the forecast at creation. Or calibrate the baseline to the resolver's rules, and until then label it "no time limit; real odds are lower".
- Show the `expired` share beside every cut, since it measures the gap.

**3. The overall and setup cuts count the same bet twice and break the bootstrap's independence assumption.**
- Location: `calibration.rb:17` and `:20-21`, with `distinct` at line 44.
- The overlap rule runs per author. An agent forecast and an operator forecast on the same proposal share levels and window, so both survive.
- In `all` and in each setup cut, a paired proposal is therefore two observations. n is inflated, 20 is reached sooner, and the interval is too narrow.
- Fix: dedupe by `order_proposal_id` in the cuts that mix authors. Keep one forecast per proposal, preferably the agent's, which is always present. Or restrict `all` and `setup` to agent forecasts and show the operator separately.

**4. The paired cut stops being paired after the overlap rule.**
- Location: `calibration.rb:29` feeding `figures` at line 35.
- `figures` runs `distinct` separately for each author's forecasts. Horizons can differ, so `checked_through` differs. The agent's A2 can be dropped as overlapping while the operator's H2 on the same proposal survives.
- The two "paired" rows then have different n and different proposals, which defeats the point of the cut.
- Fix: in `paired`, apply overlap at the proposal level. Walk the proposals per instrument, keep the first, and drop both forecasts of a dropped proposal. Then skip `distinct` for this scope.

**5. There is no head-to-head statistic in the paired cut, and the operator's anchored forecasts are included.**
- Location: `calibration.rb:25-30`, and the screen text at `show.html.erb:12`.
- Each author gets a separate skill-against-levels verdict.
- "Agent: better than the levels, Operator: not distinguishable" invites reading the agent as better than the operator, but that difference was never tested. §0.3 intends a paired comparison.
- Fix: add a per-proposal difference `brier_agent − brier_human`, with the same bootstrap and floor, as the paired cut's headline.
- `saw_agent_forecast` is stored but unused. Operator forecasts made after looking at the agent's are anchored. Exclude them from the paired cut, or split them out, and show how many were dropped.

**6. The overlap window depends on the outcome of the first forecast.**
- Location: `calibration.rb:46`.
- Whether the next forecast counts depends on the first one's `checked_through`. A quick stop-out frees the name, while an expiry blocks it for the full horizon.
- A forecaster can therefore have a different set of forecasts counted after losses than after wins.
- Fix: block through the planned window end (`starts_on` plus the horizon, as in finding 1's approximation), regardless of the outcome.

**7. Smaller statistical points.**
- `calibration.rb:51-67`: figures are stored below the floors. The screen and email gate on `scored?`, but a later reader such as the step 6 `research_summary` tool would see them. Persist only `n`, `open`, `voids`, `overlapping` and `instruments` until n ≥ 20.
- `calibration.rb:72`: `sort_by(&:first)` leaves tied probabilities in arbitrary order across buckets, and agents tend to repeat 0.6 and 0.65. Add a tiebreaker such as `[p, id]` so buckets are reproducible.
- `stats.rb:13`: the percentile bootstrap of a mean of 20 binary-driven differences is anti-conservative. It is fine as a stated approximation. The setup cuts also multiply the chances of a chance "better", and nothing says so. A note on the screen would cover it.
- The stop-wins rule is applied to the Brier headline. Only the hit rate gets the ambiguous-as-hit range. A one-line check of whether the verdict flips under the alternate rule would show whether stop-wins drives it.

## Fine as built
- **Wilson interval** (`stats.rb:21-26`): matches the standard formula and is safe at n ≥ 10.
- **Bootstrap indices** (`stats.rb:17`): 250 and 9749 of 10,000 are correct. The bootstrap is paired in the right sense, per forecast against its own geometry, and the fixed seed is reproducible.
- **Reliability buckets**: `min(n/10, 5)` buckets, sizes within one of each other, at least 10 each.
- **Hindsight Brier**: `p(1−p)` is the best constant, and it is labelled as hindsight.
- **Invariants**: nothing is computed on render. The only live read is the `Forecast.open.count` at `research_controller.rb:7`, a row count shown as "open now" beside dated figures, which is acceptable. One audit row is written per run, in the same transaction as the snapshots. The `latest` scope returns nothing on an empty table.
- **Voids and ambiguity**: void forecasts and `never_entered` are excluded, and voids are shown by reason on every cut.

## Screen and email
- **No "lower is better".** The screen (`show.html.erb:20`) and the email headline (`research_helper.rb:15`) print Brier numbers without saying lower is better. They also don't say that the skill's `+` means the forecast beat the levels. Add the phrase "(lower is better)" and "+ = better than the levels".
- **No stale-figures warning on the screen.** The email flags figures older than `FRESH` (6 days), which correctly catches an 8-day-old Saturday snapshot on Sunday. The screen only prints the date. Add the same warning there, because "open now" is live next to stale figures.
- **Below-floor wording is good.** "Not enough forecasts yet (n scored; 20 needed)" and the reliability floor line both say it plainly.
- **Paired text.** Line 12 is honest that the pair is "not independent". Once finding 5 is fixed, say how many operator forecasts saw the agent's first.

## Simpler
- `CalibrationSnapshot#scored?` re-derives the floor from a constant at read time. Storing `scored` or `floor` in `figures` would keep old snapshots consistent if the constant changes.
- Otherwise the structure is already about as small as it can be.
