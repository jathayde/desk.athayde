# Phase 2.5 step 3 review: thesis reviews

Every finding below comes from reading the code. I did not run the specs or `bin/ci`.

## Defects

### 1. A review gets raised next to a proposal that's already waiting on the instrument (tag added; after deploy or exit)
`app/models/allocation/planner.rb:22`: the tagged check sends the line to `review()` before the instrument lock and the `occupying` check at `:29-30`.
- **Tag added while a rebalance is pending:** the pending mechanical rebalance stays approvable, and a review is raised beside it. That breaks "never gets a mechanical proposal".
- **After deploy or exit:** the operator's handwritten entry or exit is `occupying`. The next night the drift is still outside the band, so the planner raises a fresh review and sends another alert.

**Fix:** in `review()`, call `OrderProposal.lock_instrument!(account, instrument)` and return `verdict("existing_proposal")` if `account.order_proposals.occupying.exists?(instrument:)`, before the hold check. Also have `Instrument#classify!` (`instrument.rb:52-55`) refuse, or name, pending `origin: :allocation` proposals when it adds `leveraged` or `amplified`.

### 2. Tag removed while a review is open: the review is orphaned and a mechanical proposal is made beside it
Without the tag, `planner.rb:23-34` never looks at `ThesisReview.open`. It proposes a rebalance, and the review stays open in the queue with nothing refreshing it. If the operator then deploys from it, the instrument carries two intents.

`show.html.erb:5` also renders "TQQQ is tagged : the discipline…" because `[] .to_sentence` is `""`.

**Fix:** before `:23`, `return verdict("existing_proposal", thesis_review: open_review) if (open_review = ThesisReview.open.find_by(instrument:))`. In the view, show "no longer tagged leveraged or amplified" when the tag intersection is empty.

### 3. Refreshing and deciding can race, so a decided review gets new numbers
`app/models/thesis_review.rb:28-29` does `open.find_by` and then `update!(context:)` with no row lock. If `decide!` (`:44-46`) commits between those two statements, the job writes tonight's numbers onto a held review. This matters because `hold_standing?` (`target.rb:52`) takes the hold's side and its `as_of` from that context. The hold then stands on numbers the operator never saw, and the drift row says "a thesis review is waiting for you" while it points at a decided review.

**Fix:** `review = open.lock.find_by(instrument:)`; this waits on `decide!`'s lock and returns nil once it's decided. Then create a new review, or leave it to the hold check.

A smaller issue in the same spot: the decision form doesn't carry the `as_of` it was shown. If the job refreshes while the page is open, the hold records a side and date the operator didn't see. **Fix:** post `context["as_of"]` as a hidden field and raise `StaleObjectError` in `decide!` when it no longer matches.

### 4. Two creators race: the unique index fires and the review is never linked
`thesis_review.rb:30`: two raisers hit the partial unique index. Examples are a `perform_now` rerun (it bypasses `limits_concurrency`) or step 4's `deployment_ask`. The second raises `ActiveRecord::RecordNotUnique`, which falls into `drift_job.rb:40`'s generic rescue. That night's row becomes `reported` with an SQL error and no link to the review.

At most one open review still holds, because the index enforces it.

**Fix:** taking the instrument lock from #1 serialises the raisers. Also `rescue ActiveRecord::RecordNotUnique` → `open.lock.find_by(...)` and refresh that one.

### 5. Same-day rerun after a decision loses the link, or raises a second review
`drift_job.rb:35` skips rows that already have `order_proposal_id`, but not rows that have `thesis_review_id`.
- **After a hold:** on the rerun, `hold_standing?(before: day.date)` checks the empty range `today...today`, so `none?` is true and the row becomes `rejected_standing`. `write` (`:53`) then sets `thesis_review: nil`, which deletes the link the migration comment promises.
- **After deploy or exit:** the rerun creates a second review that same day and sends a second alert.

**Fix:** in `record`, add `|| drift.thesis_review&.decision.present?` to the skip guard. In `planner.rb:46`, pass the held review through: `verdict("rejected_standing", thesis_review: held, held: true)`.

### 6. `hold_standing?` reads holds from the wrong set of reviews
`app/models/allocation/target.rb:51-52`:
- **Any reason counts:** `ThesisReview.decision_hold.where(instrument:)` includes `deployment_ask` holds. That reason is already allowed by the check constraint.
  - Such a review has no `as_of`, so `context.fetch("as_of")` raises `KeyError`. The planner then writes an error row on that instrument every night and never asks again.
  - `rejection_standing_now?` (`:56`) raises too, which takes down the targets screen.
  - With no notional, `side` falls back to `"0"`, so a deployment hold would quietly suppress sell-side reviews.
- **Holds carry across targets:** the lookup is by instrument, not by this target. Retire a target and add a new one on the same instrument, and the new target starts with the old hold. `standing_since?` (`:69`) sees no rows on the new target, so `none?` is true and the hold stands.

**Fix:** `ThesisReview.reason_drift.decision_hold.where(id: drifts.select(:thesis_review_id)).order(:decided_at).last`. This needs #5's fix so the link survives a rerun. It also adds account scoping, which is missing here and in `raise_for!` (`thesis_review.rb:28`).

### 7. A retired target leaves its review open forever
`target.rb:32`: `retire!` doesn't touch an open review. The review stays in `ProposalsController#index` (`:7`) and in `Desk#open_review_count` (`desk.rb:42`) with numbers that never change, and nothing says why.

**Fix:** in `retire!`, name the open review in the audit data, or refuse to retire until it's decided. On the show page, add "target retired; last measured {as_of}" when the instrument has no active target.

### 8. The review goes stale and nothing says so
- **Drift back inside the band:** the line's action is `none`, so `planner.rb:20` returns early. The open review keeps the last outside-band numbers and keeps asking. **Fix:** show the instrument's latest `Allocation::Drift` row on the review page ("back inside the band since …"), or have the job mark the review when its target's row is `none`.
- **Thesis frozen when empty:** `thesis_review.rb:29` refreshes only `context`. A review created with no thesis never picks up a trade or watchlist thesis written later. **Fix:** on refresh, `review.thesis ||= thesis_for(...)`. A thesis that is already set stays as the original.

### 9. Crashes when a context key is missing or empty
- **Show page:** `show.html.erb:14` calls `Date.parse(context["as_of"])`, and `:16-18` call `BigDecimal(context[...])`. A nil value raises `TypeError` and `""` raises `ArgumentError`. The nil-safe `percent`, `points` and `money` helpers never get to run.
- **Mail:** `alert_mailer/thesis_review.html.erb:1` and `.text.erb:1` have the same problem with `weight` and `target_weight`.
- **Where `""` comes from:** `thesis_review.rb:25-26` uses `.to_s`, so nil becomes `""`, which survives `.compact` (`:27`) and reaches `side` (`:37`). `fetch`'s default only covers a missing key.
- **Step 4:** a `deployment_ask` review will have none of these keys, so its page and mail crash outright.

**Fix:** write all context values as `x&.to_s`. Add a `ThesisReview#number(key) = context[key].presence&.then { BigDecimal(it) }` and use it in the view, the mail and `side`. Guard the `as_of` heading. Also make the subject in `Alert.thesis_review` (`alert.rb:14`) depend on `reason`, since "drifted" is wrong for a `deployment_ask`.

### 10. Smaller items
- `show.html.erb:27` shows Exit when nothing is held (no `context["quantity"]`). The exit form then fails on `position_coverage`. Show it only when `context["quantity"]` is present.
- Decided reviews appear nowhere in the UI. `proposals/index.html.erb` lists only open ones, so a hold can only be reached by URL. Add them to "Decided".
- The migration has no database guarantee that a hold has a reason. Add a check constraint: `decision IS DISTINCT FROM 'hold' OR decision_reason IS NOT NULL`, and `(decision IS NULL) = (decided_at IS NULL)`.

## Spec gaps
- **`spec/models/thesis_review_spec.rb`** doesn't cover:
  - a tag added while a rebalance is pending, which should give `existing_proposal` and no review (#1);
  - the night after a deploy whose manual proposal is still pending, which should raise no second review (#1);
  - a tag removed while a review is open (#2);
  - a same-day rerun after a hold, which should keep the link and still stand the next night (#5);
  - a same-day rerun after a deploy, which should raise no second review (#5);
  - a `RecordNotUnique` on the raise, which should end in a linked row rather than an error row (#4);
  - a refresh after `decide!`, which should leave the decided review's context untouched (#3);
  - a hold lifted by the drift going back inside the band and by the side flipping. Only "stands" and "cleared" are tested;
  - a retired target, and a re-added target not inheriting the old hold (#6, #7);
  - a review raised with no thesis picking one up on refresh (#8).
- **`spec/requests/thesis_reviews_spec.rb`** doesn't render the show page or the mail with a sparse context (no `as_of`, no `weight`, a `deployment_ask` review) (#9), or an untagged instrument in the callout (#2).
- **`spec/models/allocation/planner_spec.rb:67-75`** covers only the first raise. Nothing tests the order of the tagged check against `occupying`, or that `hold_standing?` ignores `deployment_ask` holds.

## Needs a decision from you
Should deploy or exit re-ask the next night if no proposal was written? With fix #1, a pending proposal suppresses the re-ask. Without one, a review is raised again every night. Either way, record the answer under §8's "Step 3 decisions".
