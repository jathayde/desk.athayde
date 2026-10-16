I read every file in your list and didn't run the specs. Most findings below are from reading the code against the invariants, and I list the spec gaps at the end.

## Defects

**1. Refresh races a decision, and can write onto a decided review.** `app/models/thesis_review.rb:28-29`
- `open.find_by` takes no lock. If `decide!` commits between that read and `review.update!(context:)`, the job rewrites the context of a review that is already decided.
- The drift row then points at a decided review with `action: thesis_review`, and nothing is open.
- For a hold, `context["as_of"]` and `context["notional"]` are the inputs to `hold_standing?` (`target.rb:52`). A late write moves the standing window.
- Fix: use `open.lock.find_by(instrument: …)`, the same row lock `decide!` takes at line 44. If the lookup finds nothing, fall through to create.
- Related: `decide!` blocks until the whole nightly transaction commits, because the job holds the row lock from the refresh. The operator then decides on numbers they never saw.
- Fix: post the review's `updated_at`, or the context `as_of`, with the form. Raise `StaleObjectError` in `decide!` if it changed.

**2. Concurrent create loses to the unique index and the night is recorded as an error.** `thesis_review.rb:30`
- If a rerun and a job race, the loser gets `RecordNotUnique`. `DriftJob#record` (`drift_job.rb:40-44`) turns that into `reported` with `error`, so the refresh never happens.
- No duplicate is created, because the partial index holds.
- Fix: `rescue ActiveRecord::RecordNotUnique` inside `raise_for!`, then re-run the locked find from fix 1 and refresh.
- Better: take `OrderProposal.lock_instrument!(account, instrument)` in `Planner#review`. The review path currently takes no instrument lock; only the proposal path does, at `planner.rb:29`.

**3. The thesis is never refreshed.** `thesis_review.rb:29`
- The refresh path updates only `context`. A trade opened or closed since, or a watchlist item added, never reaches an open review.
- This breaks "the review shows the original thesis (open trade, else watchlist)".
- Fix: `review.update!(context: context, thesis: thesis_for(...))`. Skip the write if nothing changed so `updated_at` stays honest.

**4. Deploy and exit are re-raised the next night. A hold is the only decision that stands.** `planner.rb:45-48`, `target.rb:50-53`
- After deploy or exit there is no open review and no standing record. If the operator abandons the form, or the proposal is still pending or awaiting hand placement, the next night's drift raises a fresh review and a fresh alert.
- The same happens within a day, because a same-day rerun sees no open review.
- The review path also runs before the `existing_proposal` check at `planner.rb:30`, so it asks while a proposal on the instrument is waiting.
- Fix, two parts:
  - In `plan`, run `OrderProposal.lock_instrument!` and the `occupying.exists?` check before the `review` branch, so a tagged instrument gets `existing_proposal` too.
  - Treat a deploy or exit decided since the drift last crossed the band like a hold. Generalise `hold_standing?` to `ThesisReview.where.not(decision: nil)` with a side check.
- Choose one explicitly. If deploy and exit should stand until the operator's proposal resolves, the occupying check covers it. If they should never stand, say so in §8.

**5. A tag removed between nights.** `planner.rb:22`, `target.rb:51`
- The open review stays open forever. The planner now treats the instrument as untagged and proposes mechanically, so a proposal and a review sit side by side.
- A standing hold is ignored for an untagged instrument, because `rejection_standing?` looks only at rejected proposals. The mechanical path proposes straight through a hold.
- The view line `show.html.erb:5` renders "is tagged : the discipline…" with an empty sentence.
- Fix:
  - In `plan`, route to the review branch when the instrument is tagged or has an open review. Both a mechanical proposal and an unreachable review are bad.
  - Make `rejection_standing?` also consult `hold_standing?`.
  - Guard line 5 of the view: say "no longer tagged" when the intersection is empty.

**6. A tag added between nights.** `planner.rb:22-23`
- The review branch runs before `rejection_standing?`, so a rebalance rejection standing on an instrument that has just been tagged is ignored. The operator is asked again.
- Combined with fix 4's ordering, the occupying check also covers a pending mechanical proposal left over from the night before the tag was added.
- Fix: call `rejection_standing?` in `review` as well, or state in §8 that the first review ignores it.

**7. A target retired or re-added with a review open.** `target.rb:67-70`, `thesis_review.rb`
- Retiring a target leaves its review open with no refresh. It stays in the queue and in `Desk#open_review_count` (`desk.rb:42`), showing numbers from an old close, as "Now (the Oct 14 close)".
- Re-adding a target for the instrument creates a new target id. `standing_since?` reads only `drifts` of that new target, so an old hold's window is empty. `none?` on an empty set is true, so the hold stands forever even if the drift returned inside the band under the old target.
- Fix:
  - Make `standing_since?` read drifts by `instrument_id` through `Allocation::Drift` joined to targets, not through `self.drifts`.
  - In the view, index and mail, show the age of `context["as_of"]` and warn when it is older than the latest check.
  - Optionally, have `retire!` list open reviews for that instrument in its notice.

**8. A missing or nil context key crashes the view and the mail.** `show.html.erb:14,16-18`, `thesis_review.html.erb:1`, `thesis_review.text.erb:1`, `thesis_review.rb:37`
- `BigDecimal(nil)` raises `TypeError` for `weight`, `target_weight`, `drift`, `band`, `close` and `notional`. `raise_for!` calls `.compact`, and `context` defaults to `{}`.
- A `deployment_ask` review (allowed by the migration check at line 19) has no weight, so its page and mail crash. `Date.parse(context["as_of"])` fails the same way.
- `side` defaults a missing notional to "sell".
- Fix:
  - Add a `ThesisReview#figure(key)` returning `BigDecimal(context[key]) if context[key]`.
  - The helpers `percent`, `points` and `money` already return "unknown" or "unavailable" for nil, so pass `figure(:weight)` and so on.
  - Guard the as_of line.
  - Make `side` return nil when there is no notional, and render "Back to target" only when it is present.
  - In the mail, wrap the weight sentence in an `if`.

**9. A rerun unlinks the drift row from its review.** `drift_job.rb:51-53`, `planner.rb:46`
- After a hold, a same-day rerun gives `rejected_standing`, and `write` sets `thesis_review: nil`. The row loses the link to the review that raised it.
- Fix: in `write`, keep `drift.thesis_review_id` when `verdict.thesis_review` is nil and the action is `rejected_standing` with `held`. Or have `review` return the hold's review in the verdict.

**10. Deploy on a sell-side drift.** `show.html.erb:26`, `decisions_controller.rb:9`
- Deploy always opens an entry (buy) form, even when `review.side` is "sell".
- Not a safety issue, since the form goes through the guardrails. It is still misleading.
- Fix: show the side next to the buttons, or label it "Deploy (buy more)".

**11. Long thesis in the redirect query.** `decisions_controller.rb:9-10`
- The thesis rides in the query string of a GET, and agent theses run to paragraphs. A very long one risks URL limits.
- Fix: `truncate` it at about 1,500 characters, or pass `review_id` and prefill server-side.

## Invariants checked and holding
- No mechanical proposal for a tagged instrument: the tagged check at `planner.rb:22` runs first and returns before `Proposals::Create`.
- One open review per instrument is enforced by the partial unique index, not just by code.
- A review never places or sizes an order: the redirects carry only the symbol and the thesis.
- The planner's run survives a failing review, because each line is in its own savepoint.
- Alerts fire only after the outermost commit, so a rolled-back run sends nothing.

## Spec gaps
- **Fix 1:** no test that a refresh skips a review decided in the meantime.
- **Fix 2:** no test for `RecordNotUnique`, a same-day rerun, or two calls to `raise_for!`.
- **Fix 3:** no test that the thesis is refreshed on a later night.
- **Fix 4:** no test of deploy or exit followed by another drift. The decided review stays untested and the pending-proposal ordering is unexercised.
- **Fixes 5 and 6:** no tag removed or added between nights, including an open review with a standing hold on an untagged instrument.
- **Fix 7:** no target retire or re-add with a review open.
- **Fix 8:** no empty-context or `deployment_ask` page or mail. The mail itself has no spec, only the subject line is asserted.
- A hold lifted by the drift returning inside the band or changing side is not exercised. Only "Ask again" is. The same goes for `rejection_cleared_at` before and after `decided_at`.
- Nothing covers a nil `unrealized_pnl` with a present `quantity` in the view.
- A request spec for `StaleObjectError` under a real concurrent `decide!` would be good, since the current one is sequential.
- The `Desk#open_review_count` account scoping has no test.
- In `planner_spec.rb:67-75`, the leveraged case never asserts `existing_proposal` precedence or a repeated night.
