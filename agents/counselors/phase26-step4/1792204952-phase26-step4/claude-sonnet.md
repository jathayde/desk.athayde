I reviewed the working-tree files, which match the staged set. `Bash` is disabled, so I couldn't run `git diff --cached`. I read the model, migration, four controllers, `proposals.rb`, `proposals/create.rb`, `order_proposal.rb`, `propose_order.rb`, the research partial and helper, `Research::Stats`, `Research::Digest`, and the relevant parts of `Trade`. I did not read `db/structure.sql`, the mailer partials, `show.html.erb`, or the specs beyond a grep of `hypothesis_spec.rb`. Nothing was edited or run, so every finding below comes from reading the code.

## Findings, most severe first

**1. The sample's R values are still editable after the look and after the freeze.** `app/models/hypothesis.rb:66-67,80-81`, `app/models/trade.rb:157,165-170`
- **What's wrong:**
  - The evidence is read live from `trades.realized_r`, and `evidence` stores only the mean and the trade ids, not each R.
  - `Trade#review` accepts a new `planned_stop` on any trade that isn't a bootstrapped closed one. That changes `initial_risk` and therefore R after the outcome is known.
  - A trade with `realized_r` nil (stop not yet reviewed) is silently dropped from `closed_trades` by `.where.not(realized_r: nil)`. When it is reviewed it slots into the first `min_sample` by `closed_at` and displaces a later trade.
  - `closed_at` itself comes from the closing leg, which a late sync can change.
- **Failure scenario:** The page shows "verdict if decided now: p 0.012 against 0.01, does not clear". The operator reviews a losing trade, moves its stop wider to raise `initial_risk`, and so shrinks that trade's R loss. The verdict now clears, it is frozen, and nothing in `evidence` shows the change.
- **Fix:**
  - Write the per-trade R values (`rs`, id-keyed) into `evidence`.
  - Let only trades with `needs_review: false` count toward `ready?` and the sample, so R is final before it is evidence.
  - List the closed trades that have no R in the verdict as "unscored" rather than dropping them.

**2. The research page computes the verdict on render, repeatedly.** `hypothesis.rb:76`, `_hypotheses.html.erb:12,24`, `research_helper.rb:46-47`
- **What's wrong:** `verdict` is not memoized, and each call runs two 10,000-draw pure-Ruby loops over n values. The partial calls it twice per ready, undecided hypothesis (lines 12 and 24), and `decide!` computes it again. `hypothesis_progress` adds per-row `open_trades.count` and `closed_trades` queries.
- **Failure scenario:** Eight ready hypotheses with `min_sample` 200 cost roughly 1–3 s each per render, so the page takes tens of seconds. This breaks the stored-rows-only rule in §3.
- **Fix, simplest:** The page shows only n, mean R and "ready". The full verdict is computed in `decide!`, frozen, and shown from `evidence` afterwards. At minimum, memoize with `@verdict ||=` and drop the second call.
- **Related:** The "Accept" button's `verdict["clears"]` guard can go too, since `decide!` already refuses.

**3. Retiring a `proposed` hypothesis raises a database error, so the page returns a 500.** `db/migrate/20261017130001_create_hypotheses.rb:39`, `hypothesis.rb:61`, `_hypotheses.html.erb:28`
- **What's wrong:** The check `(status = 'proposed') = (tested_at IS NULL)` fails for `retired` with `tested_at` NULL. `retire!` allows `from: proposed`, and the view offers Retire on proposed rows. The controller rescues only `ArgumentError`, so the resulting `PG::CheckViolation` is unhandled.
- **Fix:** Change the constraint to `status IN ('proposed','retired') OR tested_at IS NOT NULL`, plus `status <> 'proposed' OR tested_at IS NULL`. Retiring before testing then correctly leaves a hypothesis out of m, because it was never in the family. Add a spec for it.

**4. Naming a hypothesis can refuse an entry, which breaks the invariant that a hypothesis never blocks an order.** `order_proposal.rb:274-278`, `proposals/create.rb:39-40`
- **Failure scenario:** The form loaded while hypothesis #4 was `testing`, and #4 is retired before submit. Or the agent passes a retired id, or a `setup` that differs from the hypothesis's setup. `RecordInvalid` becomes `Refused` and the entry is not proposed. A real trade opportunity is lost over research bookkeeping.
- **Fix:** Follow step 1's rule that a forecast never decides what is proposed. If the hypothesis isn't testing or the setup disagrees, drop `hypothesis_id`, keep the proposal, and say so in the tool answer (like `forecast_note`), with an audit row. Keeping the strict validation would also mean the agent can't tell the wrong id from a refusal.

**5. The "clears" rule and the tests behind it.** `app/models/research/stats.rb:26-37`, `hypothesis.rb:86-87`
- **Sign-flip null:**
  - It assumes R is symmetric around 0.
  - R is bounded near −1 with a long right tail. Under a true mean of 0 the real sampling distribution is right-skewed, so its upper tail is heavier than the flipped null's.
  - The p-values are therefore too small (anti-conservative), most visibly at small n and at bars like 0.01 or below.
- **The lower bound is decorative.** It is a 5th-percentile bound, not at the Bonferroni level, and it isn't in `clears`.
  - With m = 5 (bar 0.01), a verdict can clear with a "95% lower bound" below 0, which reads as contradictory.
  - `mean.positive?` is redundant, because with a one-sided p at or below the bar (always under 0.5) the mean is already positive.
- **Float ties:** `it >= observed` (`stats.rb:29`) compares floats exactly. Sign patterns that tie mathematically but sum in a different float order get missed, which makes p slightly too small. Use `>= observed - 1e-9`.
- **Rounding mismatch:** `clears` uses the unrounded p and bar, but the stored `p_value` and `bar` are rounded to 5 places (`hypothesis.rb:86-87`). A frozen row can read "p 0.00714 against 0.00714: does not clear".
- **Fix, which also simplifies:** Use one centered-bootstrap routine.
  - p = share of resampled means of `r − mean` that are at least the observed mean.
  - Lower bound = the percentile at the bar level (`bar × draws`) of the resampled means of `r` itself.
  - Clears = lower bound > 0. This replaces the sign-flip function and keeps p and the interval consistent. It is still not exact for skew at small n, so keep the "most will read not enough trades" caveat.
- **Fine as is:**
  - The one-sided direction.
  - The `(k+1)/(draws+1)` smoothing.
  - The percentile index (`floor(draws × 0.05)` is the 5th percentile).
  - The sample being the first `min_sample` by `closed_at, id`, which is deterministic.
  - Excluded trades being counted and listed.

**6. m depends on when the operator presses Decide.** `hypothesis.rb:82`
- **What's wrong:** `Hypothesis.ever_tested.count` is read at decision time, so the operator controls m.
- **Failure scenario:** A borderline hypothesis (p 0.03) is decided accept while m = 1, before starting the next two tests. At m = 3 it would have failed.
- **Fix:** Count the tests whose `tested_at` is at or before the `closed_at` of the `min_sample`-th trade. The verdict is then a pure function of rows. The preview equals the frozen value, and there is nothing to time.

**7. Retiring a ready `testing` hypothesis freezes no verdict.** `hypothesis.rb:60-62`
- **What's wrong:** Retire is allowed at any time and `evidence` stays nil. The family count is safe, since `tested_at` is already set. But a failed result can be buried with no record of it.
- **Fix:** When `ready?`, `retire!` writes the verdict into `evidence` and the audit row. If frozen verdicts are meant to be a complete record, that matters.

**8. The database freezes less than the migration comment says.** `migration:5,50-52`
- **What's wrong:** `tested_at`, `tested_by_id`, `decided_at`, `decided_by_id`, `decision_note` and `status` are all free to move.
  - `tested_at` is what defines the family count m.
  - The trigger enforces no state machine, so rejected → accepted, or rewriting `tested_at`, passes at the SQL level.
- **Fix:** Raise when `OLD.tested_at`, `OLD.decided_at`, `OLD.decided_by_id` or `OLD.decision_note` is non-null and changes. Add a small status-transition allow-list.

**9. Audit gaps.**
- **`proposal_created`:** The audit row (`proposals/create.rb:30-31`) doesn't carry `hypothesis_id`. The tie between a trade and a hypothesis, which is the evidence, has no audit row. Add `hypothesis: proposal.hypothesis_id`.
- **Other paths:** `hypothesis_created` and `hypothesis_status_changed` are fine, and the verdict rides in the latter.

**10. Smaller items.**
- **Controllers:** `HypothesesController#create` doesn't rescue `ActiveRecord::InvalidForeignKey`, so a bogus `setup_id` or `parent_id` gives a 500. The status controllers don't rescue `RecordInvalid` or `StatementInvalid`.
- **Memoization:** `@closed_trades` (`hypothesis.rb:66`) survives `lock!`. That is harmless within a request but misleading.
- **Closed-trade ordering:** Selecting the first n by close time favours fast losers, because stop-outs close first. That is conservative for a positive-edge claim, but state it in the docs.

## Checked and fine
- **Claim freeze:** The claim columns are frozen by the whole-row trigger. `evidence` is frozen once set. Hypotheses can't be deleted or truncated. `hypothesis_id` on proposals is frozen by the `order_proposals` trigger, and the NULL → value change is blocked too.
- **Holdout:** The holdout check (NY creation date) is in the database, and the model message is plain.
- **Authorization:** All four controllers require an approver, and `decide!` re-checks the status under `lock!`.
- **Family count:** m counts the hypotheses ever moved to testing, so writing variants and never testing them doesn't inflate or shrink it. Evidence only accrues once a hypothesis is testing, so untested variants can't gather any.
- **Schwab and setups:** The research page and the digest make no Schwab calls and read rows only. Setups are not gated by hypotheses.
