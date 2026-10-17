I read the listed files and checked the trigger text. Nothing was edited or run. The invariant mostly holds, with two real breaks and a few smaller seams.

## 1. Invariant

**A. A hypothesis changes the collar and the sizing, through the setup.** `app/models/proposals.rb:18,47` is the path.
- `Proposals.draft` calls `name_hypothesis` at line 18. That sets `proposal.setup ||= hypothesis.setup` (line 47).
- Line 22 then reads `RiskRule.params_for("stop_collar", setup: setup)`, and `Sizing.for_proposal` runs on the same proposal.
- Scenario: the same entry, with no setup given, gets different collar parameters, and possibly a different quantity, depending on whether a hypothesis was named and survived `name_hypothesis`.
- Whether it survives depends on research state: `collecting?`, `holdout_from` and the hypothesis's setup. Dropping it silently reverts the setup to nil.
- That breaks "no hypothesis is an input to … sizing, or what is proposed". It also breaks the line-36 comment that research bookkeeping never decides what is proposed.
- The effect depends on whether per-setup `stop_collar` or sizing rules exist. If none do, it is latent.
- Fix: take the setup only from the caller. A hypothesis with a different setup is dropped with a note, and a nil setup is never filled from it.
- Fix, alternative: call `name_hypothesis` after the collar and sizing are frozen, so the hypothesis only sets the `hypothesis` association.

**B. A forecast error refuses the proposal before it is evaluated.** `app/models/proposals/create.rb:36-37,57-58` is the path.
- `record_forecast` runs before `evaluate!`. A bad probability or horizon raises `Refused`, which rolls back the savepoint.
- The row, the `proposal_created` audit and the halts that `evaluate!` would have engaged are all lost.
- Scenario: an agent entry with `probability: 1.2` breaches a rule that trips a rule-halt. The agent gets "forecast: …", the halt never engages, and no audit row records the refusal.
- That makes the forecast's validity decide whether the proposal exists, and whether a halt engages. The comment at line 36 only covers `Unmeasurable`.
- Fix: validate probability and horizon with a pure check before the halt checks and the draft. After that, `record_forecast` can only raise `Unmeasurable`, which is already handled.

**C. The hypothesis is checked against stale state.** `app/models/order_proposal.rb:22,295` and `create.rb:21-29`.
- The `collecting?` validation runs on the in-memory hypothesis loaded at draft time.
- The features snapshot sits between the draft and the lock. It can make several Schwab reads with retries, so the window is seconds.
- Scenario: the operator retires the hypothesis in that window. The validation still passes, because it never reloads, and the entry is named on a retired hypothesis.
- Fix: re-run `name_hypothesis` against `hypothesis.reload` under the lock, just before `save!`.
- The `RecordInvalid` rescue at line 44 would also turn a race that does fire into a `Refused` entry. Rescue it for the hypothesis and drop the name instead.

**D. The database does not freeze the proposal's own levels.** `structure.sql:83-96`.
- `measures_frozen` freezes only the reference fields, `features`, `hypothesis_id` and `quote_at_approval`.
- `limit_price`, `stop_price`, `target_price`, `planned_stop`, `setup_id`, `quantity`, `sizing` and `collar` are unfrozen at the database.
- The forecast copies these at write time and its trigger freezes the copy. The forecast's header says its levels are "always the proposal's own".
- A later edit to `target_price` would leave the proposal and its forecast disagreeing.
- I found no app path that writes them after create, since the update calls are limited to `guardrail_results`/`evaluated_at` and `child_action`. So this is a gap in enforcement, not a live bug.
- Fix: add them to the trigger, with `quantity` and `sizing` exempt only if a path legitimately writes them.

**Fine.**
- `app/models/research/features.rb` has no readers in `app/` apart from the skeptic prompt.
- The skeptic note only reaches the prompt and the page.
- `Forecast` and `Baseline` feed nothing in `Submission::Submit#check_*` or the evaluator calls I could see. I did not read `Guardrails::Evaluator`, so grep it for `forecast`, `features` and `skeptic`.
- `Trade#review` freezing the planned stop on evidence trades (`trade.rb:171`) restricts edits. It is not an input to a guardrail.

## 2. `Proposals::Create`

- **No Schwab call under the lock.** The halt checks, the draft and the features all run before the lock. Under the lock there are only DB reads, `save!`, the audits, `Forecast.record!` and the evaluator.
- **The evaluator is not checked.** `Guardrails::Evaluator` runs under the lock (line 37) and I did not read it, so check it for quote or Schwab reads. That is the one remaining risk, and it was there before Phase 2.6.
- **The rescue at lines 42-43 is too broad.** `RecordNotUnique` is now raised from anywhere in the transaction, including the forecast insert and the audit insert. Any of them gets reported as "already has a proposal waiting".
  - The comment says only the save can collide, and that is no longer true.
  - `proposal` can also be nil there if the draft's own query ever raises it.
  - Fix: rescue the exception around `save!` only.
- **A post-commit failure turns a success into an error.** Lines 39-40 run after the commit. If `Alert.new_proposal` or `SkepticJob.perform_later` raises, for example with the queue down, the caller gets an exception for a proposal that exists.
  - The tool's agent will likely re-propose and get "already waiting". A failed alert also skips the skeptic enqueue.
  - Fix: rescue and report each separately, with the skeptic wrapped on its own, since it is advisory.
- **Audit gaps.**
  - Every `Refused` path leaves no audit row: the halts, the already-waiting check, the unresolved check and the forecast error. The halt refusals predate this phase.
  - A missing features snapshot, or one with values missing, writes no audit. That is acceptable, since the reasons are inside the frozen `features`.
  - `hypothesis_not_named` and `forecast_not_recorded` are audited correctly inside the transaction.
- **Order is otherwise right.** The forecast is written before the evaluation, so an `Unmeasurable` leaves the savepoint usable. That `rescue Unmeasurable` precedes `rescue ArgumentError`, which is the correct order since `Unmeasurable < ArgumentError`.
- **The planner path is fine.** Rebalances have no features, no forecast and no skeptic (`skeptic_due?` requires an entry). If the planner raises `ActiveRecord::Rollback` at `planner.rb:103`, the after-commit alert registered inside is dropped.

## 3. Triggers against existing writers

I found nothing that existing Phase 2 or 2.5 paths write that the triggers would now refuse. The checks are listed below.
- **Update paths.** `evaluate!`, `reject!`, `expire!`, `expire_unplaced!`, `record_shadow!`, `record_submitted!`, `record_unknown!`, `record_rejected!`, `record_not_placed!`, `record_reconciled!`, `record_broker_outcome!`, `link_shadow_order!` and the sweep all go through `transition!` or `update!`.
  - They write only status, timestamps, `broker_order_id`, the attempt fields and `guardrail_results`. None touch the frozen columns.
  - Rails writes only changed attributes, and `with_lock` reloads first, so no stale jsonb is written back.
- **Approval quote.** `start_submission!` sets `quote_at_approval` from NULL, which the trigger allows. It cannot run twice, because submission leaves `validated`.
- **Column types.** `features` and `quote_at_approval` are `jsonb`, so `IS DISTINCT FROM` is valid. A plain `json` column would have errored on every update.
- **Skeptic note.** `record_skeptic_note!` uses `update_columns` with note, risk and run set together, which satisfies the check constraint. It writes nothing when the note is blank.
- **Skeptic re-run.** The job guards with `skeptic_due?` and a concurrency limit, so a second write is unlikely. A stale instance that does re-run would hit the trigger and fail the job, which is harmless but noisy.
- **Journal linker.** I did not read the journal linker's own code. A grep of `app/` shows no writes to `order_proposals` from it. It writes `Trade` and `TradeLeg`, not `order_proposals`.
- **Hypothesis rows.** `hypotheses_frozen` blocks deletes, and `order_proposals.hypothesis` is `restrict_with_exception`. No path nullifies `hypothesis_id` after the fact.

One small point: a skipped skeptic run (the daily cap) counts as a non-failed run in `skeptic_job.rb:15`. That proposal never gets a retry, even on a later day. That is probably intended, and the `skipped` status keeps it visible.

## Priority

1. A: the hypothesis feeding the setup, which feeds the collar and sizing.
2. B: validate the forecast before the lock and the draft.
3. The `RecordNotUnique` rescue scope and the post-commit failures.
4. C: re-validate the hypothesis under the lock.
5. D: freeze the proposal's levels at the database.
