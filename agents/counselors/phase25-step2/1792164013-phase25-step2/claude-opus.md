# Phase 2.5 step 2 review: rebalance proposals

Five things need fixing. The most serious is that a rebalance you approved in shadow gets proposed again the next night. I read every file the brief listed. I couldn't run `git diff HEAD` because there was no shell tool, so I read the modified files directly. Nothing here was run, including the specs.

## Defects

**1. Shadow-approved and resting rebalances get proposed again (the planner misses `submitted` rows)**
- **Where:** `app/models/allocation/planner.rb:26`
- **What happens:** the "existing proposal" check covers proposed, validated and unresolved rows, but not `submitted`. A shadow approval waiting for you to place it by hand stays `submitted` and never expires. Nothing has been placed yet, so the next night's drift is unchanged and the planner creates a second SELL 11 XYZ on a new drift row.
- **Why nothing stops it:**
  - `index_order_proposals_one_open_per_instrument_and_side` only covers proposed and validated rows.
  - `one_per_allocation_source` is keyed on the drift row, which is new each night.
  - `Proposals::Create` (`create.rb:20,22`) only checks waiting and unresolved rows.
  - `PositionCoverage` passes because 40 shares held is more than 11.
- **Also in real mode:** a DAY order that is still `submitted` at 17:10 because the orders sync is late triggers the same thing. `Book#stale_inputs` only requires a positions sync after the close, not an orders sync.
- **Fix:** check `where(status: %w[ proposed ] + OrderProposal::COMMITTED)`, which includes `submitted`.
- **Spec gap:** `planner_spec.rb:86` only tests a waiting proposal. Add `submission_unknown` and a shadow approval awaiting hand placement.

**2. A night when the drift can't be measured clears a standing rejection**
- **Where:** `planner.rb:49`
- **What happens:** an `unavailable` row has `drift = nil`, so `d.drift && …` is false, `all?` fails, and the next measured night proposes again. Plan §0.6 and §8 say only "back inside the band" or "changes side" clear a rejection.
- **Fix:** `target.drifts.where(as_of: …).where.not(as_of: day.date).where.not(action: "unavailable").all? { … }`
- **Spec gap:** only the "Ask again" path is tested. There are no specs for the drift returning inside the band, changing side (`planner.rb:47`), or an unavailable night in between.

**3. Expiry date: a Schwab call while holding the lock, and holidays get a fake close**
- **Where:** `planner.rb:53-58`, evaluated at line 28 after `lock!` at line 25.
- **Broker call under the lock:** `MarketDay.for` calls `fetch`, a Schwab `market_hours` request, for any day that isn't a Schwab row yet. That request then runs under the advisory lock and inside the job's transaction, which contradicts Create's rule that "no lock is held across a call".
- **Holidays:** if Schwab doesn't answer, the fallback row counts every weekday as a session. A run on the evening before a holiday (Thanksgiving, for example) would set expiry to 16:00 on the closed day, and the tick expires the proposal before the next real session.
- **Fix:** compute the expiry once in `DriftJob#perform` before the transaction and pass it to the planner. Require `session.schwab?` as `perform` already does at line 15. If no Schwab-sourced next session is known, record `reported` with a reason instead of guessing.
- **Spec gap:** no spec covers Friday to Monday, or a holiday.

**4. One refused proposal can still roll back the whole run**
- **Where:** `drift_job.rb:31-38` and `planner.rb:31`
- **What happens:** `Proposals::Create`'s `OrderProposal.transaction` joins the line's savepoint instead of opening its own.
  - If `save!` raises `RecordNotUnique`, Postgres marks that savepoint as failed.
  - Create turns the error into `Refused`, and the planner rescues it inside the same savepoint.
  - `drift.update!` at line 38 then fails with `InFailedSqlTransaction`, and the outer transaction rolls back every row and proposal from the run.
- **Other crashes:** any exception that isn't a `Proposals::Error` raised from `plan` (`tagged?`, `params_for`, `MarketDay`, `Lots`, `evaluate!`) also ends the whole run, because `record` has no rescue.
- **Fix:**
  - In the planner, wrap the create call as `OrderProposal.transaction(requires_new: true) { Proposals::Create.call(...) }` so a database error rolls back only its own savepoint before becoming `Refused`.
  - In `record`, rescue `StandardError` around each line's savepoint. Write the row as `reported` with `"error" => e.message` in a fresh savepoint and call `Rails.error.report`.
- **Spec gap:** neither path is tested.

**5. A rebalance buy fill can overwrite your plan on a legacy trade**
- **Where:** `app/models/journal/linker.rb:100-106`
- **What happens:** `adopt_proposal` only skips trades that already have an `order_proposal_id`. A bootstrapped or reviewed trade has its setup and planned stop set by `Trade#review`, which doesn't set `order_proposal`; that's my reading of the code, so confirm it. When a rebalance buy fills on that trade, its setup and planned stop are set to nil, the thesis becomes "Rebalance…", and the trade is flagged `missing_stop`.
- **Second issue:** at line 89, a rebalance buy that opens a new trade is never flagged `missing_setup`, because a proposal exists, and line 105 clears that flag anyway.
- **Fix:** adopt only when `proposal.requires_bracket?`. For a rebalance, link the leg without taking over the trade's plan.

## Smaller defects

- **Blocked rebalances are proposed again every night:** `planner.rb:22,26`. If a rule rejects a rebalance (for example `max_position_exposure` set below the target weight, or settled cash short), the planner proposes it again every night. Each attempt creates a new `rejected_by_rules` row and sends `Alert.new_proposal` (`create.rb:29`). The drift row also says "proposed" for a proposal the rules blocked. Suggested fix: treat a same-side `rejected_by_rules` from the previous check as `reported` with `"refused"`, and only mark `proposed` when the proposal was validated.
- **Several buys in one run each count the same cash:** `Context#projected_settled_cash` only subtracts proposals already at the broker, so each validated buy passes settled cash and the daily notional cap on its own. Approval re-checks this, so nothing goes out over the limit. Still, plan §0.6 says open allocation proposals count as committed intent, and that isn't implemented yet.
- **No minimum-notional rule means no floor:** `planner.rb:40`. If the `min_rebalance_notional` rule is missing, the minimum silently becomes 0, while a missing `rebalance_band` makes the run unavailable. Pick one behaviour; making it unavailable would match the band rule.
- **Limit price for unheld instruments may be an after-hours price:** `book.rb:85`. The quote's `last` can be an after-hours print, which then becomes the next day's DAY limit. Prefer the quote's regular-session close if Schwab returns one.
- **The "sub_share" verdict doesn't exist yet:** plan §0.6 names `detail: sub_share`, but a zero-share line only shows up as `below_minimum`. With a minimum of 0 it falls through to a quantity validation refusal.

## Specs that don't test what they name

- **The opening-exposure gates:** `planner_spec.rb:30-38` only asserts `pass`, so a rule that wrongly skipped would still look fine. Add one case each where it should bite:
  - settled cash is short;
  - an earlier rebalance buy counts toward `per_day`;
  - an unheld rebalance buy counts toward `max_positions`;
  - `daily_loss_halt` and `max_drawdown_halt` are not `skipped`.
- **Stop adjustment on a rebalance sell:** no spec drives `Submission::Place#adjust_stop` for a rebalance sell with a working stop, so that invariant isn't tested anywhere.
- **Shadow order matching:** no `Submission::Matcher` spec checks that a rebalance (a plain order with no child) matches a hand-placed order.
- **"Makes the check step aside":** `e2e/allocation.spec.js:18` and `lib/playwright/scenario.rb:104` seed the `existing_proposal` drift row directly, so the job never runs and the test only checks a label. The rebalance scenario likewise creates its proposal directly rather than through the planner, which is fine for the screen but doesn't test the planner.
- **Exit rules on a rebalance sell under a halt:** nothing checks that a rebalance sell still goes through while entries are halted by a rule. The halt spec only uses a manual halt, which refuses before any row is written.

## Checked and fine

- The rule changes in `max_positions`, `max_position_exposure`, `settled_cash`, `notional_cap`, both halts, `stop_collar`, `max_risk_per_trade` and `position_coverage` branch on the new predicates.
- `earnings_blackout` and `max_sector_exposure` stay entries-only, as the plan says.
- The payload is a plain LIMIT with no child, and Submit, Place and the Matcher branch on what the order does.
- The Create lock and the planner lock are the same key.
- `submission_unknown` is in `UNRESOLVED`, so the planner's check covers it.
- Allocation proposals are audited with the system as actor.
- `orders/protection_watch.rb:22` (`kind: :entry`) means a position bought by a rebalance never gets the hard "unprotected" alert, only the dashboard banner. That matches §8 as written, but it's worth confirming it's deliberate.
