I reviewed the working files rather than the diff, because Bash is disabled here and `git diff --cached` wouldn't run. I didn't read the specs, the other staged views, or `Proposals`. Line numbers are from the current files.

## Findings, most severe first

**1. `app/models/trade/costs.rb:46-51`: a trailed stop is scored against the original stop.**
- The stop cost compares the fill with `@trade.planned_stop`, which is the original plan.
- Scenario: the operator trails the stop up to break-even, and it triggers at 100 against a planned stop of 90. The code records a cost of −10 a share, tagged `comparable`.
- `gross_r` then subtracts that, so gross R lands far below realized R. Setup `gross_avg_r` is poisoned the same way. The opposite case also exists: a stop moved down and hit below the plan.
- Fix: compare the fill with the stop order's own `stop_price`, which the closing leg's `activity.order` should carry (`Position` already reads `stop_price` off orders). Tag it `comparable` only when that price still equals the planned stop. Otherwise tag it `not_comparable` or skip it.

**2. `app/models/trade/costs.rb:50`: a trade with no proposal gets a `comparable` stop cost.**
- `proposal&.shadow?` is nil for a trade with no proposal, so the tag falls through to `comparable`.
- The planned stop on such a trade was typed in at review, possibly after the fact. It is not a frozen plan.
- Fix: require `proposal` for a `comparable` tag, and use `unavailable` or nothing otherwise.

**3. `app/models/decay_check.rb:16`: the new-close rule compares timestamps.**
- It skips when the last check's `last_closed_at >= max(closed_at)`. A trade that becomes eligible without closing later than the previous maximum never triggers a row.
- Scenario: a trade closed last week, got its R through review, and joins `since_sample` now. It is silently left out until some later close.
- Also, `decay_checks.last` orders by `as_of` alone. A rerun on the same day, or a backfill, has ties and an undefined "last".
- Fix: compare the trade-id sets with `trades.map(&:id) == last&.trade_ids`, and order by `[:as_of, :id]`. The `trade_ids` column is already stored, so this is also simpler.

**4. `app/models/decay_check.rb:21`: repeated looks still inflate false alarms.**
- Once per new close is still about one look per week. Each look is a 2.5% one-sided test (`stats.rb:21`, percentile bootstrap on a single trade each).
- A percentile bootstrap at n=20 on skewed R undercovers, so the real rate is higher. Over a year of weekly looks, a flag on a healthy hypothesis becomes likely.
- The flag is advisory only, so the harm is limited to cry-wolf emails.
- Fix: require the flag on two consecutive checks before it reaches the Sunday email, or use a wider interval such as 99% for the flag. Alternatively, drop the "95%" wording in `decay_summary`, since the flag is not a 95% test.

**5. `app/models/hypothesis.rb:72`: `since_sample` only counts closed trades.**
- Trades that are open and deep underwater are absent until they close. The mean runs optimistic exactly when a hypothesis is decaying through slow losers.
- Fix: say so on the `/research` line, or add a count of open named trades to the check row.
- Trades with a nil `realized_r` drop out silently in the same way. The count is shown only through `n`.

**6. `app/helpers/research_helper.rb:77-79`: a number computed on render.**
- With no check yet, `decay_summary` calls `since_sample`. That loads every named trade for each accepted hypothesis on each `/research` render.
- It is small, but it breaks "computed on render beyond what is cheap" in the loop at `_hypotheses.html.erb:13`.
- Fix: show "none yet" with no count, or store the count on the hypothesis.

**7. `app/models/setup.rb:32-36`: gross and realized averages cover different trades.**
- `gross_avg_r` averages only trades with a `comparable` cost, while `avg_r` averages all of them. The Sunday email puts them side by side.
- Reading "gross 0.9 vs net 0.4" overstates the cost, because the subsets differ.
- Fix: also store the realized average over the same subset, or show gross minus realized over that subset only.

**8. `app/models/trade/costs.rb:46-51`: a stop that fills in several legs.**
- A stop that fills in parts only has its last leg measured, via `closing_leg`. The cost is undercounted but stays correctly signed and tagged.
- Fix: accept it and note it in the comment, or sum the exit legs that share the closing leg's order.

## Checked and fine

- **Entry arithmetic (`costs.rb:34-43`).**
  - It uses the weighted fill from priced initial legs against the approval mid.
  - The sign is positive when you paid more than the mid.
  - Units match `initial_risk`, which is also in original-entry units.
  - The `r` is nil with no risk, and `gross_r` skips entries with no `r`.
  - Realized R is real cash, so adding back only the comparable costs does not double count.
- **Entry tags.**
  - Shadow, same-session fill versus later-session fill, and `unavailable` ordering are correct.
  - The `unavailable` check runs before the fills check, and the early return when there is no quote is deliberate.
- **Split handling (`costs.rb:49`).** `planned / ratio`, then `(planned − price) × ratio` over `quantity / ratio`, correctly returns to original units.
- **Sample ordering (`hypothesis.rb:72`).**
  - `drop(min_sample)` runs before the closed/R filter, so the sample stays fixed in proposal order.
  - Naming an accepted hypothesis cannot move the verdict. `decided?` freezes `evidence`, and new proposals sort after `sample.last`.
  - `ready?` only guards proposals created before the last sample trade.
- **Invariants.** The check writes only a row and an audit event, and changes no rule or setup. The unique index on `[hypothesis_id, as_of]` plus `limits_concurrency` guards double runs. The bootstrap is seeded, so reruns agree.
- **Audit.** The row is written outside a transaction with the `create!`. A crash between them would leave a check with no audit row. Wrapping both in `transaction` is a small, optional fix.

## Simpler alternative

Replace the `last_closed_at` comparison with a trade-id set comparison (finding 3). The `last_closed_at` column and the `max` call can then go.
