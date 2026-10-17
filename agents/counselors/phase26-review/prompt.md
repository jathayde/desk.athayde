# Phase-level review: Phase 2.6 (the quant research track)

Review the whole phase, `git diff 026da4f..HEAD` (the plan is `docs/phase-2.6-plan.md`; each step was reviewed alone, and §8 records what changed). Read-only: do not edit or run anything that writes.

This review is for what the step reviews could not see, the seams between steps:
1. **The phase invariant:** every number on a page is read from a stored row; no forecast, probability, calibration figure, hypothesis, or model-written text is an input to a guardrail, to sizing, or to what is proposed; nothing a decision rests on is editable after the fact. Find any path that breaks it, across steps (for example a forecast, a hypothesis name, a feature snapshot, and a skeptic run all hanging off one Proposals::Create).
2. **Proposals::Create as it now stands:** the order of halt checks, draft, features (Schwab reads), the lock, the save, the hypothesis drop, the forecast, the evaluation, the after-commit alert and skeptic. Any Schwab call under the lock, any refusal that loses a halt, any audit missing.
3. **The freeze triggers on order_proposals:** several migrations replaced `order_proposals_measures_frozen()` in turn, and step 6 added a second trigger. Is the final function what each step meant? Can anything an existing Phase 2 or 2.5 path writes to order_proposals now be refused (status transitions, evaluations, sweeps, the allocation planner)?
4. **Statistical coherence across steps:** the forecast scoring rule, the frozen baseline, calibration's maturity and overlap rules, the hypothesis sample, the decay check's reading of the frozen sample, and costs. Do they agree with each other?
5. **Load and cost:** what runs per proposal, per night, per Saturday, and per page render; the skeptic's spend.
6. **What the plan promised and the build does not do,** or does differently without saying so in §8.

Report findings by file and line, most severe first, each with a concrete failure scenario and the fix. Say plainly when something is fine.
