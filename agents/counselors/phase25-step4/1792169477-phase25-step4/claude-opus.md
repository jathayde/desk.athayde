# Phase 2.5 step 4 review: cash inflows, deployment and the context panel

There are 11 defects. Items 1–4 can lose or double-count a deposit and should block the step. Items 5–8 should ship with it, and 9–11 are minor.

## Blocking

**1. A deposit is marked done on any night it buys nothing, even when the cause only lasts that night. Normal ACH settlement is one of those causes.**
`drift_job.rb:37` marks the deposit `done` whenever `proposed == 0`. `deploy`/`deploy_to` report several outcomes as "not proposed", but most of them only apply to that one night:
- `planner.rb:46`: `expires_at` is nil, so the planner returns `[]`. For drift, the same condition just waits for the next night (`planner.rb:32`, plan §8 line 106). For a deposit it ends things.
- A manual or rule halt: `create.rb:15-16` raises `Refused`, `planner.rb:73` turns that into "not proposed: halted…", and the deposit is marked done.
- "blocked by settled cash": `Guardrails::SettledCash` is a built-in block (`evaluator.rb:5`), and an ACH deposit stays unsettled for days. So an `immediate` deposit is usually blocked on its first night and then permanently abandoned as cash. This is the normal path, not an edge case. Plan §8 line 88 retries a blocked rebalance nightly; a deposit gets no retry. Each blocked buy also saves a `rejected_by_rules` proposal and sends one alert, so one deposit can send N mails.
- "a proposal is already waiting" on every target (`planner.rb:67`).

Tranches have the same flaw: `deployment_tranche.rb:25` marks the last tranche `done, left_as_cash` on a halted or blocked night.

**Fix:** have `deploy` return a category for each outcome:
- *proposed*
- *nothing to buy*: under one share, or under the minimum
- *deferred*: no expiry, refused, blocked, or a proposal already waiting

The job should mark `done`/`roll!` only when nothing was proposed and nothing was deferred. If anything was deferred, leave the deposit `pending` (or the tranche `scheduled`), record why in its detail, and audit it. To avoid the opposite failure, see item 7: a deposit that stays pending forever pauses drift buys forever, so cap the number of retry nights.

**2. A staged deposit loses money when two tranches come due on the same night.**
- `cash_inflow.rb:56` dates the tranches from `detected_at`. Staging from a review decided late (`thesis_review.rb:73`) therefore makes several tranches due immediately. Example: decide "stage over 3" two weeks after the deposit, and all three are due tonight.
- `drift_job.rb:40` loads every due tranche in one pass. Tranche 1 proposes. Tranche 2 finds "already waiting" on every target and calls `roll!`, which adds its amount to tranche 3 in the database (`deployment_tranche.rb:24`).
- But tranche 3 is the in-memory copy loaded before that update, so `planner.deploy(tranche, tranche.amount)` uses the old amount. The rolled money is never spent, and if tranche 3 rolls too, the sum is computed from the wrong amount.
- The same stale read happens whenever several tranches are due after nights the check was unavailable.

**Fix:**
- In `stage!`, take a `from:` date: today (`MarketDay.today`) when staged by a decision, the detection date otherwise.
- In `settle`, `tranche.lock!` (which reloads it) before deploying.
- Propose at most the earliest due tranche per deposit per night, and leave later ones `scheduled` (they are still due tomorrow).

**3. Detection ignores the activity's status and sign (`cash_inflow.rb:23-24`).**
- `Activity#flow_amount` (`activity.rb:35`) takes `net_amount.abs`, so `flow_amount&.positive?` is always true. An inbound-type activity with a negative amount (an ACH return) becomes a positive deposit to deploy. The sync only quarantines it as `flow_sign_disagreement` (`activities_job.rb:79`) and still records it as kind `deposit`.
- Nothing filters on `status`, so a canceled or pending deposit row deploys.

**Fix:** add `.where(status: [ nil, Schwab::Activity::VALID ])`; `valid_for_journal` alone drops nil, which `Schwab::Activity#valid?` accepts. Then require `next unless activity.net_amount&.positive?`.

There is also no handling when a deposit is later reversed, re-synced as another kind, or followed by a withdrawal. The sync can change `status`, `net_amount` or `kind` on the same row (`activities_job.rb:77`), but a deposit stays `pending`/`staged` with its recorded amount. **Fix:** in `drift_job.rb:33` and `:40`, before deploying, check that `inflow.activity` is still a VALID deposit with `flow_amount == inflow.amount`. If not, change its status to `done` with `reversed:` and audit it.

**4. The weeks field on the deposit review isn't validated (`_deposit.html.erb:12`, `thesis_review.rb:73`, `cash_inflow.rb:52-53`).**
- `"0"` divides by zero: a 500 the controller doesn't rescue.
- A negative number makes `weeks.times` create no tranches. The deposit's status becomes `staged`, but it isn't `committing` and never becomes `done`, so it is stranded silently.
- Values over 52 are accepted, though the policy caps weeks at 52 (`deployment_policy.rb:10`).
- `"abc"` puts `Integer()`'s raw error message in the flash.

**Fix:** in `decide!`, before the `update!` at line 62, parse the weeks and raise `ArgumentError, "weeks must be 1 to 52"` unless they are in 1..52.

## Should ship with the step

**5. A deposit that keeps failing pauses drift buys indefinitely.** `deploy_to` (`planner.rb:73`) only rescues `Proposals::Error`. Any other error from `Proposals::Create`/`draft` rolls back that deposit's whole `settle` and leaves it `pending`. That is the right outcome for one night, but `pending` counts as `committing`, so if the error repeats, every drift buy is reported as `committed` forever. **Fix:** rescue `StandardError` per target in `deploy_to` as a deferred outcome, and use item 1's retry cap.

**6. Rolled and done tranches aren't audited.** `deployment_tranche.rb:16` only logs when the status is `proposed?`. Going to `rolled` or `done`, and the next tranche's amount increase at line 24, leave no audit row. **Fix:** always log `deployment_tranche_status_changed` with before and after, plus `rolled_into` and the new amount when it rolls.

**7. The push for a deposit review says "No thesis on file".** `alert.rb:14` falls back to "No thesis on file. Open the review to decide." for a `deployment_ask`. The mail templates are correct. **Fix:** for a deposit review, use "The policy says ask each time." as the body.

**8. Settling a deposit doesn't check the deposit itself.** `settle_deposit!` (`thesis_review.rb:70`) doesn't lock the deposit or check it is still `asked`. The review's lock and `open?` check do block a second decision on the same review. But anything else that has moved the deposit on (item 3's reversal) would be overwritten. **Fix:** `cash_inflow.lock!` and raise `StaleObjectError` unless it is `status_asked?`.

## Minor

**9. The paused-buys flag can be missed mid-run.** `deploying?` (`planner.rb:59`) only caches a true result. A deposit committed by `InflowJob` partway through the 17:10 run is deployed in that same run, after drift buys were already proposed on other instruments. The buys can't double up on one instrument because of the `occupying` check, but that check makes the deposit lose its share on those instruments (item 1's "already waiting"). One fix is to deploy only deposits detected before the run started (`detected_at < run start`).

**10. Other loose ends:**
- `planner.rb:47`: the drift query isn't scoped to the account. That's safe only while one account trades.
- `planner.rb:47-49`: a target whose drift row is unavailable is dropped silently, and the split is spread over the rest, so other targets get more than their weight. Defer the deposit instead.
- If every eligible target weighs 0, `whole` is 0 and the division at `planner.rb:51` raises.
- A deposit with no `trade_date` is never detected (`cash_inflow.rb:23`).

**11. Copy and status nits:**
- An `immediate` deposit stays `proposed` forever; nothing moves it to `done`.
- `_deposit.html.erb:3` can never show, because a deposit under the minimum is never asked about.
- "deploying at tonight's check" (`decisions_controller.rb:10`) is wrong after 17:10.
- When staging is decided without weeks, the default comes from `DeploymentPolicy.current`, not the policy in force at detection. In practice it's always 4, because an `ask` policy has no weeks.

## What holds

- **Reruns:** rerunning the 17:10 job doesn't deploy twice, because both loops only pick up pending deposits or scheduled tranches.
- **Detection:** a deposit is detected once (unique `activity_id` plus `RecordNotUnique` rescued inside a savepoint), and backfilled history before the first policy doesn't count.
- **Arithmetic:** the split can't exceed the amount. Each share rounds down to the cent, each target buys `floor(share / close)` shares at a limit of `close`, and the last tranche takes the remainder.
- **Decisions:** `decide!`'s lock and open check stop a second decision, and the partial unique index allows only one open review per deposit.
- **Policy:** the policy recorded at detection decides for that deposit; a policy change mid-staging doesn't touch existing tranches.
- **Audit:** every deposit status change is audited.

## Missing specs

- An `immediate` deposit on a night with no expiry, a halt, or a settled-cash block stays `pending` and deploys the next night (item 1).
- Staging decided two weeks late: due dates start from the decision. Two tranches due the same night: the rolled amount is the one deployed (item 2).
- A non-VALID deposit and one with a negative amount aren't detected; a reversed deposit isn't deployed (item 3).
- Weeks of 0, -2, 53 and "x" through the request spec (item 4).
- Audit rows for rolled and done tranches (item 6).
- A deposit review decided twice through the controller; only drift reviews are tested now.
- The push or alert body for a deposit review (item 7).
- Drift buys resuming once the deposit is no longer committing, and drift sells still proposed while it is.
- A withdrawal while a deposit is staged.
