# Phase 2.6 review, part A: the invariant, Proposals::Create, and the triggers

I stayed inside the listed files and ran nothing. Two findings break the phase invariant: in both, a hypothesis decides something about the proposal. Most severe first.

## 1. Severe: naming a hypothesis changes the setup, and sizing and the rules read the setup
**`app/models/proposals.rb:18`, `:22-23`, `:47`; `app/models/proposals/create.rb:37`**

`draft` calls `name_hypothesis` at line 18, before it computes the collar and the sizing. Line 47 then runs `proposal.setup ||= hypothesis.setup`. After that:
- **Sizing:** `Sizing.for_proposal(proposal)` (line 23) sees the hypothesis's setup.
- **Evaluator:** `Guardrails::Evaluator` (create.rb:37) sees it too.
- **Collar:** line 22 does not. It uses the local `setup` keyword, which is the caller's value and is nil in this case.

This causes two problems:
- **(a) The invariant breaks.** Naming a hypothesis changes which per-setup parameters sizing and the guardrails use. `RiskRule.params_for(..., setup:)` shows that per-setup parameters exist. I couldn't check whether `Sizing` reads `proposal.setup` because it's outside scope. If it does, a hypothesis feeds sizing directly.
- **(b) One proposal is sized and collared for two different setups.**

**Scenario:** The agent proposes an entry with no setup and names hypothesis H, whose setup is "breakout". Sizing and the rules use breakout's parameters. The frozen collar uses the defaults. The evaluator then judges the stop against a collar built for a setup the proposal doesn't have.

**Fix:** Don't take the setup from the hypothesis. When the entry names no setup, or a different one, drop the hypothesis with a `hypothesis_note`. If §0.5's "a named entry takes the hypothesis's setup" is deliberate, then §0.5 contradicts the invariant as written and the plan needs to settle which wins. In that case, at least move the adoption ahead of line 22 and have line 22 read `proposal.setup`.

## 2. Severe: a hypothesis's status can refuse a proposal
**`app/models/proposals.rb:41`; `app/models/order_proposal.rb:22`, `:294-298`; `app/models/proposals/create.rb:29`, `:44-45`**

`name_hypothesis` checks `collecting?` when the proposal is drafted. The `names_a_testing_hypothesis` validation checks it again at `save!`. The candle and feature reads from Schwab (several seconds) happen between the two checks.

**Scenario:** The operator moves H from testing to rejected, or retires it, while the agent's entry is still drafting. `save!` raises `RecordInvalid`, and Create refuses the proposal with "Hypothesis #N is rejected…". Research bookkeeping has just decided what gets proposed, which §0.5 says must never happen.

**Fix:** Under the lock, just before `save!`, run `name_hypothesis` again against a reloaded hypothesis. It drops the hypothesis and records a note, as it already does at draft time. Keep the validation as a backstop. Separately, the validation message says "being tested or accepted", which should match what `collecting?` actually covers.

## 3. Medium: `rescue ArgumentError` catches more than the author's mistakes
**`app/models/proposals/create.rb:57-58`; `app/models/forecast.rb:40`, `:47`**

The rescue wraps all of `Forecast.record!`, not just the probability and horizon checks (forecast.rb:32-33). That includes `baseline_for` and `create!`. Both `Math::DomainError` and Rails' enum errors are `ArgumentError`s.

**Scenario:** A fault in `Research::Baseline` refuses the entry with "forecast: …". A calculation on the forecast side then decides whether the proposal exists.

**Fix:** Check probability and horizon before anything else, and turn only those failures into refusals. Any other error from the forecast step should leave the proposal without a forecast, with an audit note, the same way `Unmeasurable` is handled.

## 4. Medium: the trigger freezes what the proposal saw, not what was decided
**`db/structure.sql:83-96`**

`order_proposals_measures_frozen` freezes `reference_*`, `features`, `hypothesis_id`, and the approval quote once it's set. Nothing in the database freezes:
- **What was proposed:** `sizing`, `collar`, `quantity`, `limit_price`, `stop_price`, `target_price`, `setup_id`.
- **The decision:** `decided_at`, `decided_by_id`, `acknowledged_warnings`, `override_reason`, `shadow`.

Forecasts are safe because they copy their levels when written (forecast.rb:38). But hypothesis evidence and the research joins rely on `setup_id` and the sizing, and only model code protects those today.

**Fix:**
- Freeze the first group after insert.
- Freeze each decision column once it's non-null.
- Freeze `guardrail_results` and `evaluated_at` only once `decided_at` is set, because Submit rewrites them legitimately at submit.rb:39.

None of the Phase 2 writers in these files touch the first group, so this would refuse nothing that exists today. The journal linker is outside my scope, so check it.

## 5. Low: Create's refusals leave no audit row
**`app/models/proposals/create.rb:19`, `:20`, `:26`, `:28`, `:43`, `:45`, `:58`**

Submit records `proposal_approval_refused` outside its rolled-back transaction (submit.rb:72). Create records nothing when it refuses, and the forecast refusal is new in 2.6.

**Fix:** In the rescue, log `proposal_refused` with the reason. When Create runs inside the planner's transaction, a rollback there would remove that row too. The planner already records the refusal in its verdict, so this matters mainly for the tool and the form.

## 6. Low: the halt check isn't repeated under the lock
**`app/models/proposals/create.rb:19-20`**

The settings are read before the draft and its Schwab calls. If a manual halt or a rule halt starts during those seconds, the proposal can still be saved as validated, and an agent proposal still sends its alert. `check_gates!` (submit.rb:50) refuses it at approval, so no order goes out.

**Fix:** After `lock_instrument!`, reload the settings and check both halts again.

## 7. Minor: misleading message on a duplicate forecast
**`app/models/proposals/create.rb:42-43`**

If the `Forecast` unique index fires, the operator is told "already has a proposal waiting". It can only happen through a bug, but the message would hide what went wrong.

## One thing to verify (low)
**`app/models/research/features.rb:86`**

The snapshot stores `desk.excluded_by_reason` inside the `features` jsonb. If that value has symbol keys or BigDecimals, the column will look changed in memory right after `save!`. `evaluate!` → `transition!` → `with_lock` would then raise "Locking a record with unpersisted changes" (Rails 7.1+). I can't see `excluded_by_reason` from these files. If it isn't plain strings and numbers, convert it to strings before storing.

## What's fine

- **Halts are never lost.**
  - In Create, `evaluate!` is the last statement in the savepoint, and a forecast refusal happens before it (create.rb:36). Nothing after the evaluation can roll back the halt it engaged.
  - In the planner, `propose_deployment` engages halts again after its `Rollback` (planner.rb:108). `plan` keeps the rejected row, so its halt commits with it.
  - Submit engages halts again after `Blocked` (submit.rb:23).
  - Alert and skeptic callbacks registered inside the planner's rolled-back savepoint are dropped, which is what you want for a blocked buy that gets retried.
- **No Schwab calls under the lock in Create.** The draft, the features, and the approval quote (submit.rb:19) all happen before any lock. The planner does take the lock before calling Create (planner.rb:32, :96), but it only proposes rebalances. A rebalance draft reads no candles (proposals.rb:27-30) and takes no features (create.rb:22). So the comment at create.rb:14 holds only because the planner never proposes entries. It would stop being true if it ever did.
- **The forecast doesn't decide anything.** An unmeasurable forecast leaves the proposal without one and audits it. Nothing in these files reads forecasts, features, or the skeptic note when sizing, gating, or submitting. Submit's re-check reads the frozen sizing and the rules, nothing else.
- **The triggers refuse nothing an existing path writes.**
  - `transition!` reloads inside `with_lock` and writes only the status and its own attributes.
  - Status-only writers are `evaluate!`, `reject!`, the `expire!` sweep, `expire_unplaced!`, `record_shadow!`, the record_* outcomes, and `record_broker_outcome!`.
  - `link_shadow_order!` writes only `broker_order_id`. `start_submission!` sets the quote once, from NULL. Submit's `update!` writes `guardrail_results` and `evaluated_at`.
  - The planner only inserts, and the triggers are BEFORE UPDATE.
  - The skeptic's `update_columns` (order_proposal.rb:132) still fires its trigger, but only once: `skeptic_due?` re-reads the proposal fresh, so a retry does nothing.
  - The journal linker is outside my scope. It's a risk only if it writes one of the frozen columns.
