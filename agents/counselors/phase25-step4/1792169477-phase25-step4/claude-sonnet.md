# Phase 2.5 step 4 review

I found defects in all the areas you listed. Nothing was run or edited. Everything below comes from reading the code. Three items depend on code I only inferred, and I've marked them.

## Defects that lose or misplace money

**1. A deployment that proposes nothing is marked `done` and never retried.**
- `drift_job.rb:37` sets the inflow to `done` whenever `proposed` is zero. `drift_job.rb:43` does the same for tranches through `roll!`.
- Three of the causes are one-night conditions:
  - `Proposals::Create` raises `Refused` (a `Proposals::Error`) when the desk is halted (`create.rb:15-16`). `planner.rb:73` turns that into `"not proposed: …"` for every target.
  - Every buy can be blocked by the settled-cash rule on a night the deposit has not settled.
  - `planner.rb:46` returns `[]` when `expires_at` is nil, and `planner.rb:47` returns nothing when no drift rows are usable.
- In each case the deposit goes `done`, leaves `committing` and the dashboard, and sits as cash forever. A final tranche ends as `done` with `left_as_cash`.
- This contradicts the plan's "a night whose check is unavailable … tries again the next night" (plan line 106), and plan line 88, where a blocked rebalance is retried.
- Fix: have `planner.deploy` return a distinct outcome per target. Only "under one share" and "under the minimum" are final. Everything else (halted, blocked, waiting proposal, error, no `expires_at`, no rows) means leave the source `pending` or `scheduled` and try again tomorrow. Do not call `roll!` for those. For tranches, only roll when every outcome is final.

**2. Two deposits, or backlogged tranches, on the same night: the second finds every instrument occupied.**
- The first source's proposals are in `occupying`, so the second gets `"a proposal is already waiting"` on every target. It then goes `done` or rolls, per item 1.
- A staged answer to an ask dates tranche 0 from `detected_at` (`cash_inflow.rb:56`), not from the decision. An ask answered 15 days later has three tranches due at once. The first proposes. The second and third roll forward, and the last ends as `done` with `left_as_cash`.
- Fix:
  - Date tranches from the decision date when `user` is present: `Date.current` in `MarketDay::ZONE`.
  - In `drift_job.rb:33-46`, handle one source per target per night. Leave the rest `pending` or `scheduled`, using item 1's "not final" rule.

**3. Rolled-in money is lost when two tranches of one deposit are due on the same night.**
- `drift_job.rb:40` loads all due tranches up front. `roll!` updates a freshly loaded `following` row (`deployment_tranche.rb:22-24`). The in-memory copy of that tranche still has the old amount.
- So `planner.deploy(tranche, tranche.amount)` at `drift_job.rb:42` deploys only the old amount. The rolled money is never deployed, and nothing records the gap.
- Fix: call `tranche.reload` at the top of the `settle` block, or `lock!` it. Item 2's fix of one tranche per inflow per night removes this case as well.

**4. A negative or reversed deposit is deployed as new cash.**
- `cash_inflow.rb:24` checks `flow_amount&.positive?`. `activity.rb:33-36` returns `net_amount.abs` for any deposit, so the check always passes.
- `activities_job.rb:79` quarantines a deposit whose sign disagrees but still stores it. That row then becomes a positive inflow.
- Fix: test `activity.net_amount&.positive?` directly.
- Also add `check_constraint "amount > 0"` on `cash_inflows` and `deployment_tranches` in the migration.

**5. Withdrawals, and an activity that changes after detection, are never reconciled with the deposit.**
- `pending` or `scheduled` sources do not look at withdrawals, at later changes to `net_amount`, or at the activity's status.
- A deposit that is withdrawn again, or reversed after detection, still deploys.
- Fix: at deploy time, in `drift_job.rb:34-35` and `:41-42`, re-read `inflow.activity` and require it to still be a positive deposit. Cap the amount at `min(amount, balance.settled_cash − pending_app_buys − live_broker_buys)`, reusing `Guardrails::Context#projected_settled_cash`. If that is nil, treat it as "not tonight".

**6. Several same-night buys can together exceed settled cash.**
- `Guardrails::Context#projected_settled_cash` (`context.rb:37-40`) subtracts only `at_broker` buys and unmatched working broker orders. `validated` proposals created that night are not counted, so each of the N deposit buys passes against the full settled cash.
- The approval-time re-check catches the later ones, but only after they have sat in the queue as `validated`.
- This is the only cash cap on a deployment: the other rule, the split in `planner.rb:51`, only keeps the sum within the deposit.
- Fix: item 5's cap, plus counting `proposed` and `validated` allocation buys in `projected_settled_cash`, or in `planner.deploy` for the running total.

**7. `stage!` accepts any weeks value (`cash_inflow.rb:52-56`).**
- `"0"` raises `ZeroDivisionError`, which the controller does not rescue (`decisions_controller.rb:16-19`), so it returns a 500.
- `"-2"` creates no tranches and sets the inflow `staged`. It is then not committing and never done, so the cash is invisible.
- `"08"` fails `Integer("08")` as an invalid octal. `"abc"` shows Ruby's raw message to the user. `"9999"` makes 9,999 rows.
- Fix: `Integer(weeks, 10)` and require `1..52`, matching `deployment_policy.rb:10`. Raise `ArgumentError` with a plain sentence. Add a unique index on `(cash_inflow_id, due_on)`.

## Defects in detection and the pause

**8. One bad activity stops detection of every later one (`cash_inflow.rb:25-27`).**
- Only `RecordNotUnique` is rescued. Any other error (for example from item 7, or from the `Memory::Repo` file read) aborts the loop. The savepoint rolls that inflow back.
- Every run then retries the same poison row ahead of later deposits.
- Fix: also rescue `StandardError`, call `Rails.error.report(…, handled: true)`, and continue with the next activity.

**9. One failing target sinks the whole deposit (`planner.rb:73`).**
- `deploy_to` rescues only `Proposals::Error`. Any other error propagates to `settle`, which rolls back every target's proposals.
- The inflow stays `pending`, so drift buys stay paused (closed, not open). It also retries and fails every night with no alert.
- Fix: rescue `StandardError` per target and return `"error: …"`, which item 1 treats as "not final".

**10. Race between the pause and a late deposit (`drift_job.rb:21-26`, `planner.rb:26`).**
- `deploying?` is evaluated inside the drift transaction. `deploy` runs after it commits. An `InflowJob` landing between the two produces a drift buy and a deposit buy the same night, on different instruments.
- Fix: re-check `committing` before `deploy`. If drift buys were proposed this run, hold the deposit until tomorrow.
- A rerun of the 17:10 job does not double-deploy. Sources leave `pending` or `scheduled` inside the transaction, and the job is limited to one run at a time.

**11. A proposal in a non-rejected status other than `validated` reads as "blocked" (`planner.rb:71`).**
- `deploy_to` tests `proposal.validated?`. `plan` (`planner.rb:36`) tests `!rejected_by_rules?`.
- If `evaluate!` leaves any other live status, the outcome is `"blocked by "` with an empty rule list. The tranche then rolls its money forward while that proposal is still live, which is a double deployment.
- Fix: use `rejected_by_rules?` the same way in both places.
- I did not read `evaluate!`, so I don't know whether such a status exists.

**12. Partial price nights skew the split (`planner.rb:47-49`).**
- `whole` sums only targets that have a priced, available row tonight. If one target has no close, the others absorb its share.
- Fix: compute `whole` over all eligible active instrument targets. A target with no price tonight contributes "no price tonight" to its own share and stays cash.
- `drift_job.rb:26` checks only `lines.first.action`. I did not check whether `Book` marks all lines `unavailable` together. If it can mark them one at a time, this is real.

## Audit, reviews, mail and page

**13. Tranche transitions are not audited (`deployment_tranche.rb:16`).**
- `mark!` logs only when `proposed?`. `rolled` and `done` write nothing, and the rolled-in amount change on the following tranche (`:24`) also writes nothing. This breaks "every state change audited".
- Fix: log every `mark!` with before and after, plus a `deployment_tranche_rolled` event naming the recipient and the amount.
- `mark!(…, left_as_cash: nil)` stores `""` for the key, because `transform_values(&:to_s)` runs on nil. Drop nil values before stringifying.

**14. `settle_deposit!` does not check the inflow's state (`thesis_review.rb:70-76`).**
- It moves the inflow to `pending`, `staged` or `held` from whatever state it is in. The review lock already stops a double decision.
- Fix: `cash_inflow.lock!` and raise `StaleObjectError` unless `status_asked?`. This covers "decided after its deposit was handled".

**15. The push and email body for a deposit review is wrong (`alert.rb:14`).**
- `review.thesis` is nil for an ask, so the body says "No thesis on file. Open the review to decide."
- Fix: branch on `reason_deployment_ask?` and use a body like "$X deposited <date>: deploy, stage, or hold." The mail templates are correct.

**16. A policy change mid-staging is correct as built.**
- Tranches are fixed at `stage!`, and the policy in force at detection decides. `thesis_review.rb:73` and `_deposit.html.erb:12` take weeks from `DeploymentPolicy.current` at decision time, which is reasonable because the operator is choosing then.
- `_deposit.html.erb:3` (the "Below the minimum" line) is dead. Below-minimum inflows are `done` before `ask!` runs.

**17. Three smaller points.**
- The stored `notes` is the full `deployment.md`, up to 32 KB, copied into every deployment proposal. Store a digest or a truncation if that grows.
- `planner.rb:51` raises `ZeroDivisionError` if every target weight is 0. That inflow stays `pending` and reports an error every night, per item 9.
- With no `min_rebalance_notional` rule, `deploy_to` returns "under the minimum" for everything (`planner.rb:64`), so the deposit goes `done` without ever deploying. Item 1's fix should treat that as "not final" as well.

## Spec gaps

**Model specs, `spec/models/cash_inflow_spec.rb`:**
- Rerunning `DriftJob` the same night, with no second set of proposals.
- Two deposits on one night.
- A negative deposit and a sign-disagreeing deposit.
- A deposit then a withdrawal.
- All buys blocked, halted, or `expires_at` nil, with the status asserted as still `pending`.
- Two tranches due on one night, with the amount asserted.
- Ask answered days later, with the tranche dates asserted.
- `weeks` of 0, -2, `"abc"` and `"08"`.
- A target with no price tonight.
- The `RecordNotUnique` path in `detect!`.
- One poison activity not stopping the next.
- A target that raises, with the others still proposed.
- Audit rows for `rolled` and `done` tranches.
- A natural sub-share roll. The current staged example forces it with `update!(amount: 50)`, which is how the stale-amount bug (item 3) stays hidden.

**Request specs, `spec/requests/thesis_reviews_spec.rb:72-95`:**
- A deposit review decided only by `deploy`: no stage, no hold without a reason, no second decision, no non-approver.
- No test that the mail body for a deposit review is right (a mail spec only checks the subject at `cash_inflow_spec.rb:98`).
- No dashboard test for the "Deploying …" line, and no test that drift buys resume after `done`.

**Highest priority:** items 1, 2 and 4, because they lose or misdeploy money. Item 3 follows, and items 5 and 6 are the settled-cash and withdrawal work.
