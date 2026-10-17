The review of the staged Phase 2.6 step 4 change is below. It's read-only: I edited nothing and ran nothing. Two of the findings let the evidence be changed after the outcomes are known, and one is a crash on a path the plan allows.

## Findings, most severe first

### 1. A closed trade's R can be edited, or the trade dropped from the sample, after the outcome is known
`app/models/trade.rb:165-170`, `app/models/hypothesis.rb:65-67`

- **The cause:** `Trade#review` writes `planned_stop` on any trade that isn't both closed and bootstrapped, then calls `recompute!`. The R calculation runs `planned_stop` → `initial_risk` → `realized_r`. The linker copies the proposal's stop into the trade (`journal/linker.rb:104`), but a review can overwrite it, and `closed_trades` reads `realized_r` live until the decision.
- **Scenario:** a hypothesis has 28 of 30 trades closed and two losers at −1R. The operator reviews them in the journal:
  - Lowering the stop turns −1R into −0.4R.
  - Blanking the stop makes `realized_r` nil, so `.where.not(realized_r: nil)` drops the trade, and the next trade to close takes its place in the first 30.
  - Adding a stop to an older trade with no R pulls it into the window and pushes the current 30th trade out.

  Every one of these happens with all the neighbouring R values already on screen. The audit row records the new stop but nothing ties it to the hypothesis.
- **Fix:**
  - For a trade whose `order_proposal.hypothesis_id` is set, compute the hypothesis R from the proposal's frozen `planned_stop`.
  - Refuse `planned_stop` changes in `review` on those trades.
  - Don't drop nil-R trades from the evidence. Count a closed trade with no R in the sample position its close earns, and list it as "no R" in the verdict, the way excluded trades are listed.

### 2. Judging the first `min_sample` trades by close date favours fast trades
`app/models/hypothesis.rb:65-68, 80`

- **The cause:** trades that close first are the quick stop-outs and quick targets. Slow trades are still open when the sample fills.
- **Scenario:** 30 entries are named. Twenty-five hit tight stops within days, and five trend winners run for months. The verdict freezes on the first 30 closes and rejects an edge that exists. It also works the other way: an operator who cuts losers slowly and takes winners fast gets a sample full of winners. Step 2 fixed the same bias for forecasts with the "a week after `window_ends_on`" rule.
- **Fix:** make the sample the first `min_sample` named proposals by `created_at` that filled into trades on or after the holdout date. `ready?` becomes true when all of them have closed. The sample is still fixed in advance, and the close order can no longer choose it. This also makes ties in `closed_at` irrelevant. The current tie-break, `closed_at, id`, is deterministic and fine as it stands.

### 3. Retiring a hypothesis that was never tested crashes on the database check
`db/migrate/20261017130001_create_hypotheses.rb:39`, `hypothesis.rb:61`

- **The cause:** the check `(status = 'proposed') = (tested_at IS NULL)` fails for `status = 'retired', tested_at = NULL`. `retire!` allows `from: proposed`, and the plan says a hypothesis can be retired at any time.
- **Scenario:** the operator retires a proposed hypothesis. `update!` raises a check violation, which `RetirementsController` doesn't rescue as `ArgumentError`, so the page returns a 500.
- **Why the spec misses it:** `spec/models/hypothesis_spec.rb:70` only retires an untested hypothesis with a blank reason, which fails before any SQL runs.
- **Fix:** change the check to `status <> 'proposed' OR tested_at IS NULL` plus `status IN ('proposed','retired') OR tested_at IS NOT NULL`, or simply `NOT (status = 'proposed' AND tested_at IS NOT NULL)`. Add a spec that retires a proposed hypothesis.

### 4. The decision's own columns aren't frozen once set
Migration lines 5 and 50-55

- **The cause:** only `evidence` is frozen once set. `decided_at`, `decided_by_id`, `decision_note`, `tested_at` and `tested_by_id` can all be rewritten. `status` can also go backwards at the database level (`accepted` → `testing`, or `retired` → `testing`), after which `decide!` would run again on a later sample and the trigger would refuse the new `evidence`.
- **Scenario:** a console `update_column(:tested_at, …)` moves the date the hypothesis joined the family. A status rollback makes a rejected hypothesis look as if it is still being tested.
- **Fix:** in the trigger, freeze each of those columns once it is non-null. Allow only these status moves: proposed → testing or retired; testing → accepted, rejected or retired; accepted or rejected → retired. Phase invariant: "nothing a decision rests on is editable after the fact".

### 5. Retiring after the sample fills leaves no record of the result
`hypothesis.rb:60-62`

- **Scenario:** at 30 trades the page shows "Verdict if decided now: does not clear". The operator retires the hypothesis instead of rejecting it and writes a variant. The negative result never reaches `evidence`, and the audit row has no verdict. The family count still counts it, so the bar isn't gamed, but the record of what the hypothesis showed is lost.
- **Fix:** in `retire!`, when the hypothesis is `testing` and `ready?`, freeze `compute_verdict` into `evidence` and the audit data, as `decide!` does.

### 6. The Sunday email computes the verdict, and the research page computes it twice per row
`brief_mailer/_research.html.erb:8`, `_research.text.erb:14`, `_hypotheses.html.erb:12,24`, `hypothesis.rb:76`

- **The cause:** `verdict` isn't memoized. Each call runs 10,000 sign-flips and 10,000 bootstrap draws over up to 500 trades, which is millions of operations in Ruby. The page calls it twice per ready row: line 12 and the Accept button on line 24. The email calls it once per hypothesis waiting for a decision.
- **Plan conflict:** §2 says the Sunday email reads stored rows and computes nothing.
- **More queries per row:** `hypothesis_progress` adds an `open_trades.count` and a `closed_trades` query for every row.
- **Scenario:** two ready hypotheses with `min_sample` 500 could take seconds to render and stall the mailer.
- **Fix:**
  - Memoize `verdict` (`@verdict ||=`).
  - In the email, list ready hypotheses without the clears/does-not-clear word.
  - Better still, have a Saturday job store the provisional verdict so both screens read a row.

### 7. Statistics
`research/stats.rb:24-38`, `hypothesis.rb:84-87`

- **Sign-flip test:** the mechanics are correct. It's one-sided (`>= observed`), and the `+1` correction is valid and keeps p above zero. One caveat: the null hypothesis is "R is symmetric about zero", not "mean R = 0". Realized R is skewed: many stops near −1R and a few winners at +2R or +3R. A right-skewed distribution with mean zero can produce false passes more often than α. A centred bootstrap test avoids this: resample `r − mean`, then p = (#{resampled mean ≥ observed} + 1)/(draws + 1). Alternatively, keep the sign-flip test and say in the plan what it assumes.
- **The lower bound isn't at the bar's level:** it is a fixed 95% lower bound while the bar is α/m, and `clears` ignores it, so it is decoration. Either label it "95%, not adjusted for the number tested", or compute it at 1 − α/m and require `lower_bound > 0` in `clears`. The second also covers the skew problem.
- **`mean.positive?` is redundant:** p ≤ α/m already implies a positive mean. It's harmless and can stay.
- **Float ties:** with repeated values such as many −1.0 stops, a flipped arrangement can be numerically equal to the observed mean but sum in a different order and land 1 ulp lower. That understates p by a hair. Compare with `>= observed - 1e-9`.
- **Monte Carlo noise:** at m = 10 the bar is 0.005, and the standard error of p with 10,000 draws is about 0.0007. The fixed seed makes the result reproducible, but a borderline verdict depends on the draws. For n ≤ 16, enumerating all 2ⁿ sign patterns exactly is cheap.
- **Bonferroni bar:** m counts hypotheses ever moved to `testing`, at the moment of decision, which matches the plan. Deciding before starting other tests gives a looser bar. The plan accepts this, so I'm only noting it.

### 8. Some named entries never become evidence, and there's no count of them
- **Naming before the holdout date** (`order_proposal.rb:274`): an entry can name a hypothesis in `testing` before its `holdout_from`. `open_trades` (`hypothesis.rb:70`) shows the trade, but `closed_trades` excludes it forever. Fix: require `MarketDay.today >= holdout_from` to name one, and use the same filter in both scopes.
- **Adding to an open trade** (`journal/linker.rb:103`): a named entry that adds to a trade already open from an unnamed entry is never linked (`trade.order_proposal_id` is already set), so the evidence silently loses it. The reverse case is also true: an unnamed add-on is folded into a named trade's R. At minimum, show on the page "N named entries filled without a trade of their own".

### 9. A hypothesis label can refuse an entry
`order_proposal.rb:274-277`

Step 1 settled that a forecast never decides what is proposed. A setup mismatch is the author's own mistake, like an out-of-range probability, so refusing that is defensible. A hypothesis retired between the form loading and the submit is not. That order is refused for a label. I'd drop the label, audit it as `hypothesis_not_named`, and keep the proposal. Separately, `proposals_controller.rb:52` uses `find_by`, so an unknown id silently becomes "no hypothesis".

## What's fine
- **Family count:** only `testing` and later counts. Entries can only name a hypothesis in `testing`, so variants that were never tested collect no evidence, and retiring before testing can't lower a bar it never raised.
- **Freezing the claim:** `attr_readonly`, the whole-row trigger (including the truncate trigger), and the frozen `order_proposals.hypothesis_id` all work.
- **Holdout check:** the database check is correct. `created_at` is `timestamptz` in `structure.sql`, so `AT TIME ZONE 'America/New_York'` gives the right New York date.
- **Audit rows:** there is one on every state change, with the frozen verdict on decisions and `decided_by` set.
- **Locking:** `decide!` locks the row before computing, so the verdict reads fresh rows.
- **Approver checks:** they are enforced in all four controllers, controller-side as elsewhere in the app.
- **No Schwab calls on render**, and **nothing gates a setup or an order** apart from item 9.
- **Minor race:** a `test!` running at the same moment as a `decide!` can leave m off by one. The audit row records it, so it isn't worth more than this note.

## Simpler options
- If you fix item 2 by sampling the first N named proposals, the close ordering and its tie-break go away.
- If you fix item 1 by computing R from the proposal's frozen stop, the evidence no longer depends on the journal review.
- One stored provisional-verdict row per ready hypothesis would serve the page, the email, and the decision.
