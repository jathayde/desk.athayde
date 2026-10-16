# Phase 2.5 phase-level review: allocation module

I found one defect that should block calling Phase 2.5 done: new-cash deployment ignores the operator's holds. Below it are nine defects to fix, two audit gaps, three places where the docs and code disagree, and five operator-confusion items.

I had no shell in this session, so I couldn't run `git log` or `git diff 748fa1f..HEAD`. I worked out the phase from the plan, the PRD (§5.12, §6) and the code itself. I checked the paths in the prompt against the code and the spec lists by reading; I didn't run anything.

## Blocking

**1. Deploying new cash ignores open thesis reviews and standing holds.** (`app/models/allocation/planner.rb:54`, `:69-88`)
- The nightly drift check steps aside for an open review on an untagged instrument (`planner.rb:25`) and for a standing hold (`:28`). The deployment path (`deploy`, `deploy_to`, `propose_deployment`) checks only `instrument.nil? || discretionary?`.
- **Path:** the operator holds TQQQ, then untags it, then a deposit arrives under `immediate` or a tranche falls due. A rebalance buy of TQQQ is proposed.
- This breaks two §8 step 3 decisions: "a hold keeps standing whether or not the instrument is still tagged" and "a review left open after the tag comes off is still answered before anything mechanical happens".
- No spec covers it (`spec/models/cash_inflow_spec.rb` has none).
- **Fix:** in `deploy`, skip any target that has an open review on its instrument or `target.standing_hold("buy", before: day.date)`. Make it a final outcome (`{ result: "held by you", final: true }`) so the share stays cash and isn't deferred. Add a spec.

## Should fix before done

**2. Deployment splits cash by target weights only, not by what each target is short.** (`planner.rb:55-59`)
- The share is `amount × weight ÷ Σ instrument weights`. Class targets and the cash the targets leave uninvested fall out of the denominator, and tonight's drift is ignored.
- Example: targets A 30%, a bond class 50%, the rest cash. All new cash goes to A.
- Drift sells are not paused while cash is being deployed (§8 step 4), so the next night A is outside its band and the check proposes selling what it just bought. Retiring a target mid-staging does the same: its share moves to the others.
- **Fix:** cap each share at that target's drift notional from tonight's row. That row already measures equity with the deposit in it, so the notional is the target's real gap. Anything left over stays cash.

**3. A shadow approval never placed by hand blocks that instrument forever.** (`app/models/order_proposal.rb:47`, `app/models/orders/proposal_link.rb:24-31`)
- `occupying` includes `submitted` shadow rows with no broker id. Nothing ever moves those rows out of `submitted`: `expiring` covers only `proposed`/`validated`, and I found no way to abandon one.
- Result: the drift row reads `existing_proposal` every night, each deployment share for that target defers, and a tranche on a single-target book rolls and is eventually left as cash.
- This carries over after shadow mode is turned off.
- **Fix:** leave out of `occupying` any `awaiting_hand_placement` row whose `expires_at` has passed. Or have `ProposalLink` mark it unplaced, with an audit row, once it has expired unmatched.

**4. A halt quietly turns new cash into "left as cash".** (`cash_inflow.rb:102-105`, `deployment_tranche.rb:20`, `planner.rb:89-91`)
- A halt refusal is `final: false`, so each halted night counts toward `DEFERRED_NIGHTS`.
- A 5-session halt marks an `immediate` deposit `done, gave_up_after_nights`. During staging it rolls tranches, and the last one becomes `left_as_cash`.
- Each of these writes an audit row only. There is no alert, and the deposit drops off `desk.deployments` and isn't in the Sunday email.
- **Fix:** don't count a night whose outcomes are all halt refusals. Alert (and list in the Sunday email) whenever a deposit or the last tranche is left as cash.

**5. With no active targets, a pending deposit never resolves.** (`app/jobs/allocation/drift_job.rb:19`)
- `return if lines.empty?` exits before `deploy`, so a pending inflow is never deferred or given up on.
- It stays in `committing` and the dashboard shows "Deploying … at the next check" indefinitely. If a target is added weeks later, the old deposit deploys then.
- **Fix:** run `deploy` even when there are no lines (`Planner#deploy` returns nil, which takes the defer path), or settle pending inflows explicitly.

**6. Cash drag flags a deployment that is on schedule.** (`app/models/cash_drag_diagnostic.rb:13-17`)
- Intended cash is `1 − Σ target weights`. A compliant 8-week staging is FLAGGED by week 3 under a 3-week rule, and the email says "past the 3-week threshold under a policy of staged over 8 weeks".
- A deposit the operator explicitly held as cash is also flagged.
- PRD §5.12.4 asks for divergence *from the policy*.
- **Fix:** count scheduled tranche amounts and `held` inflows as intended cash (name them in `detail`), or don't flag while tranches are scheduled.

**7. The plan's after-hours price check is missing from the verify list.** (`docs/verify-on-approval.md`, vs plan §6 and `app/models/allocation/book.rb:76-87`)
- Plan §6 lists "whether a quote's `lastPrice` read at 17:10 is an after-hours print". The verify doc has no such item; the new items are 59–62.
- At 17:10, the positions' `last_price` (which sets every held limit and every deployment limit) and the quote `last` (unheld limits) may both be after-hours prints.
- **Fix:** add the item, covering both positions and quotes.

**8. The thesis review's Deploy and Exit buttons land on a form that probably shows an error.** (`app/controllers/thesis_reviews/decisions_controller.rb:14`, `proposals_controller.rb:22,45`)
- The redirect has a symbol but no `limit_price`, so `preview` runs. For an entry, `StopCollar::Calculator.new` does `BigDecimal("")` and raises `ArgumentError`, which shows as a raw flash: `invalid value for BigDecimal(): ""`. I inferred this from reading; I didn't run it.
- The e2e test (`e2e/allocation.spec.js:70`) checks only the notice, so it would not catch it.
- **Fix:** pass `limit_price: review.close` in the redirect, or skip `preview` when `limit_price` is blank.

**9. A rejected deployment buy doesn't stand.** (`app/models/allocation/target.rb:45`)
- `rejection_standing?` only looks at rejections whose source is a drift row.
- When the operator rejects a deployment buy, the share stays cash and the deposit is `proposed`, a state nothing moves on from. Once that deposit stops pausing drift buys, the nightly check proposes the same buy on the same target, the thing §0.6 says should not happen.
- **Fix:** include buy-side rejections sourced from inflows and tranches, or record the rejected share on the inflow and say on the dashboard that it is now cash.

## Audit-invariant gaps

**10.** `app/models/thesis_review.rb:37`: refreshing a waiting review rewrites `context` with no audit row. That changes which `seen_as_of` a later decision will be refused against. **Fix:** log `thesis_review_refreshed` with the before and after `as_of`.

**11.** `app/models/deployment_tranche.rb:40`: `roll!` increases the next tranche's `amount` with no audit row on that tranche; only the rolled one records `into_week`. **Fix:** log `deployment_tranche_status_changed` (or a new `…_amount_changed`) on the receiving tranche with the before and after amounts.

## Invariants checked

- **Book rules never judge an order:** holds. The evaluator uses `active_set_for(setup)`, which defaults to the trade scope (`app/models/guardrails/evaluator.rb:12`, `app/models/risk_rule.rb:29`).
- **Same guardrails for allocation proposals:** holds. Every path goes through `Proposals::Create`, and approval re-evaluates them.
- **No Schwab order call from any job:** holds.
- **Nothing on a page render calls Schwab:** broken.
  - `app/controllers/thesis_reviews_controller.rb:9` (new in step 3) calls `PriceChart.for`, which calls `Agent::MarketData.price_history`, which reaches Schwab when the cache is cold.
  - `ProposalsController#show` and the `new` preview already did this in Phase 2. Item 8's redirect now sends operators there too.
  - **Fix:** a cache-only read on pages, or record this as an accepted exception in the plan.
- **One writer for buys:** holds within the module. The deploy path in item 1 is the exception.
- **Every state change audited:** broken by items 10 and 11. Also, when the rules block a deployment buy, the proposal is rolled back (`planner.rb:86`), so its creation and evaluation audit rows disappear. The outcome is just "blocked by the rules", without naming the rules as the drift path does (`:36`). **Fix:** name `blocking_rules` in the outcome.

## Plan and PRD contradictions

- **Plan §0.5 vs §8 step 2:** §0.5 says the limit is "editable on the proposal before approve"; §8 step 2 says it is not editable. The code follows §8. Fix the §0.5 text.
- **Plan §2 vs §8:** §2 still describes the drift job as "proposing nothing" outside step 1. That's fine, but the §3 Targets bullet says `/allocation_targets` with "the instrument page gets the tag toggles", which the step 1 note above it replaces. Strike it.
- **PRD §5.12 vs plan:** the PRD wants a per-target band, "what counts as a diversifier … versioned like every other rule", and has "the agent" generating proposals. The plan has one band rule, tags that are audited but not versioned, and a deterministic job. The user answered each of these on 2026-10-16. Add one line to §8 saying the PRD is superseded on those points, so the next reader doesn't treat them as defects.

## What will confuse the operator

**12. "Buys wait while new cash is deployed" can last a long time.**
- An unanswered `ask` (the seeded default) or a 52-week staging pauses every drift buy for as long as it lasts.
- There's no way to cancel or speed up scheduled tranches, and superseding the policy doesn't affect them.
- **Fix:** a "stop staging, leave the rest as cash" action on the dashboard line.

**13. The dashboard says buys wait while a deployment buy is already in the queue.**
- `deploy` runs after the drift rows are written, so the target's row says "buys wait while new cash is deployed" while a deployment buy for that very target sits in the queue.
- `CashInflow#progress` says "at the next check" even after several deferrals (for example, waiting for settled cash).
- **Fix:** record the deployment proposal id in that drift row's detail, and show `detail["outcomes"]`/`deferred_nights` in `progress`.

**14. A waiting rebalance stays approvable after its premise changes.**
- If its target is retired, or its instrument tagged leveraged after it was proposed, nothing on `proposals/show.html.erb` says so.
- **Fix:** a warning on the Drift panel when `allocation_source.target` is inactive or its instrument is now discretionary. Or `retire!` cancels pending allocation proposals, with an audit row.

**15. The queue, the email, and the band preview.**
- A deposit question shows in the queue as "Thesis review: $2,000.00 deposited Oct 14" (`proposals/index.html.erb:16`); it should read "Deposit: …".
- The Sunday email's Allocation section (`brief_mailer/_allocation.text.erb`) leaves out deployments in progress and open reviews or asks, which are exactly what is pausing buys.
- `Allocation::BandPreview` (`band_preview.rb:18`) skips `proposed` rows, so widening the band doesn't show "this waiting proposal would not have been made".

**16. A deployment share skipped behind a same-night drift sell on the same instrument stays cash for good** once any other target takes a share. It's visible only in `cash_inflows.detail`. Folding item 2's cap in largely settles this; otherwise show it on the dashboard line.

## Before calling Phase 2.5 done

Must fix: item 1.

Should also land, because each changes money or cash state without telling the operator: items 3, 4 and 5, and item 7's verify entry, which has to exist before shadow mode goes off because the first live rebalance limit depends on it.

The rest can be tracked.

**Scenario: shadow off for the first time with allocation proposals queued.** Shadow is decided at approval (`app/models/submission/submit.rb:39`). Proposals created in shadow will be submitted for real once shadow mode is off, as plain LIMIT orders, and verify items 60 (the plain-LIMIT shape) and 7 (the after-hours price) are both still open. Either clear those items before going live, or add a refusal in `Submission::Submit` for `kind_rebalance?` while they are open.
