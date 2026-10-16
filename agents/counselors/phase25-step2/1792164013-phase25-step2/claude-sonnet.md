I reviewed Phase 2.5 step 2 by reading the files, since Bash is disabled here and I couldn't run `git diff HEAD` or the specs. I haven't confirmed the defects by running anything. I've left the findings in this reply and written no file.

Most invariants hold, and I found no auto-execution path. The payload is a plain limit with no child. `Place`, `Submit` and `Matcher` branch on what the order does (`reduces_position?`, `opens_exposure?`, `requires_bracket?`).

## Defects

1. **An unavailable night clears a standing rejection.** `planner.rb:49`.
   - An unmeasured night writes `drift: nil, action: "unavailable"`. The `d.drift &&` test then fails, `all?` is false, and the planner re-proposes on the next measured night.
   - Fix: exclude unavailable rows, e.g. `.where.not(action: "unavailable")` on the `target.drifts` scope. Only a measured in-band night or a flipped sign should clear the rejection.
   - A knock-on at `allocation_targets/index.html.erb:23`: "Ask again" keys off the latest drift row's action. A later unavailable row hides the button while the rejection still stands.

2. **A `submitted` rebalance doesn't make the planner step aside.** `planner.rb:26`.
   - The check covers only `proposed`, `validated` and the unresolved states. In shadow mode, an approved proposal stays `submitted` with no `broker_order_id` until the operator places it by hand and the sync matches it.
   - If that hasn't happened by the next 17:10, the position is unchanged and the drift is identical, so the planner proposes the same trade again. `PositionCoverage` doesn't net committed sells either, so both pass.
   - Fix: use `OrderProposal::COMMITTED` plus `proposed` at line 26. `create.rb:20-23` has the same gap for a human proposal.

3. **A crash on one line loses the whole run.** `drift_job.rb:35-42`.
   - Only `Proposals::Error` is rescued, and that is inside `plan`. Any other exception rolls back the outer transaction, so every target's row for the night is gone. Examples: `ArgumentError` from `BigDecimal` in `Rule#param` (`rule.rb:22`), or a `Schwab::Error` out of `MarketDay.for`.
   - Fix: add `rescue StandardError => e` around the `requires_new` block. Call `Rails.error.report`, write the row as `reported` with `detail["refused"]`, and continue.

4. **The "refused by the database" case still poisons the transaction.** `planner.rb:27-32`, `create.rb:31`, `drift_job.rb:35`.
   - `Create` joins the planner's transaction, so no savepoint is created. A `RecordNotUnique` aborts the Postgres transaction. `Create` and the planner convert it to a verdict, but the next statement (`drift.update!`, line 38) raises `InFailedSqlTransaction`, which ends the run. The job comment says otherwise.
   - It should be rare, since the advisory lock and the pre-check come first.
   - Fix: wrap the `Proposals::Create.call` at `planner.rb:27` in `OrderProposal.transaction(requires_new: true)`.

5. **The expiry does network I/O under the lock, and trusts a fallback calendar.** `planner.rb:53-58`.
   - `expires_at` is first evaluated as an argument at lines 27-28, after `lock!` and inside the drift transaction. `MarketDay.for` can call Schwab there, against `create.rb:10`'s "no lock held across a call".
   - Separately, `market_day.rb:34` calls every weekday a session in the fallback calendar. If Schwab is down, a holiday Monday gets a 16:00 close, and the proposal expires before the next real session.
   - Fix: compute the expiry once in the job before the transaction, and require `session.schwab?`. If only a fallback row is available, report instead of guessing.

6. **Settled cash ignores buys that are waiting.** `context.rb:42-44`.
   - `pending_app_buys` sums `at_broker` only. Validated buys claim exposure (`pending_cost_for`, `pending_new_positions`) but not cash.
   - The job emits all of a night's rebalance buys at once, so each passes `settled_cash` against the full balance. The second approval then fails on re-evaluation with "now block; re-propose".
   - Fix: count `OrderProposal.committed.buy`, excluding the proposal being judged, in `pending_app_buys`.
   - I couldn't see the diff, so this may predate step 2, but the nightly batch is what exposes it.

7. **A missing `min_rebalance_notional` rule fails open.** `planner.rb:40`.
   - `fetch("amount", "0")` means no rule gives a minimum of zero, whereas a missing band rule makes the run unavailable.
   - Fix: report with a reason such as "no min_rebalance_notional rule".

8. **Two rules still branch on the kind.** `earnings_blackout.rb:3` and `max_sector_exposure.rb:3` use `entry?`.
   - A rebalance buy skips the "not checked" acknowledgment that an entry gets. Use `opens_exposure?`, then `Rule#entry?` (`rule.rb:23`) has no callers.
   - Update `planner_spec.rb:37-38` to expect `unavailable` for those two rules.
   - Also, `proposals.rb:13` re-implements `reduces_position?` inline. Add a class-level `OrderProposal.reduces_position?(kind, side)` next to `opens_exposure?`.

9. **Question for you: rules-blocked rebalances come back every night.**
   - A rebalance buy blocked by settled cash, the exposure cap or the per-order cap lands as `rejected_by_rules`, which isn't `rejected`. It is recreated each night and sends `Alert.new_proposal` each time.
   - If you want that quiet, treat it like a standing rejection until the blocking rule's inputs change.

## Spec gaps and specs that don't test what they name

- **Rebalance notional counting toward the daily cap:** no spec covers it.
- **`max_positions`:** no spec checks it against another target's pending rebalance buy.
- **Rule halt:** no spec covers a rule halt (entries halted, not the manual one). A rebalance sell should still be proposed and a buy refused at `create.rb:16`. The "halted desk" case at `planner_spec.rb:79-83` tests only `manual_halt`.
- **`submission_unknown` on the instrument:** no spec shows it blocking the planner. Only a waiting human exit is tested (`planner_spec.rb:86-100`).
- **Findings 1 to 5:** none has a spec. The missing cases include:
  - an unavailable night between a rejection and the next measured night;
  - a `submitted` row blocking the planner;
  - a line that raises while the run continues;
  - Friday, holiday and early-close expiry (only Wednesday to Thursday with a Schwab row is covered);
  - the rejection clearing when the drift returns inside the band or flips sign.
- **Rejection clearance controller:** there is no request spec for `rejection_clearances_controller.rb`. The planner spec calls the model's `clear_rejection!` directly.
- **Lot method:** `planner_spec.rb:50` claims the sell "takes the exit's lot method" but asserts only the proposal attribute. It never checks `taxLotMethod` in the payload.
- **Same-day rerun:** `drift_job_spec.rb:113` uses a bare factory proposal. It doesn't assert that a rerun leaves `OrderProposal.count` unchanged for a real rebalance row.
- **`rebalance_skipped` e2e:** `lib/playwright/scenario.rb:104-107` seeds the `existing_proposal` row directly, so `e2e/allocation.spec.js:18` doesn't exercise the planner stepping aside. The `toHaveCount(0)` on "SELL 11 XYZ" passes trivially. Rename it, or drive the planner in the scenario.

## Checked and fine

- `Place` still adjusts the stop for a rebalance sell, through `reduces_position?` at `place.rb:26`.
- `Matcher` expects no child for a rebalance buy.
- `ProtectionWatch` doesn't expect protection on a filled rebalance buy. That matches plan §8.
- The notional cap skips sells and counts rebalance buys through `notional_today`. That's correct, only untested.
- I didn't run the polymorphic `where(allocation_source: target.drifts)` at `planner.rb:46`, which I haven't confirmed works. `planner_spec.rb:102-118` exercises it.
