# Phase 2.6 review, part A: the invariant, Proposals::Create, and the order_proposals triggers

Each step of Phase 2.6 was reviewed alone (`docs/phase-2.6-plan.md` §8 records the changes). This review is for the seams. Read-only: do not edit or run anything that writes. Stay within these files; do not read the whole diff:
app/models/proposals.rb, app/models/proposals/create.rb, app/models/order_proposal.rb, app/models/submission/submit.rb, app/models/forecast.rb, app/models/research/features.rb, app/jobs/research/skeptic_job.rb, app/models/allocation/planner.rb, and the order_proposals trigger function as it finally stands in db/structure.sql (search `order_proposals_measures_frozen` and `order_proposals_skeptic_frozen`).

1. **The phase invariant:** no forecast, probability, calibration figure, hypothesis, or model-written text is an input to a guardrail, to sizing, or to what is proposed; nothing a decision rests on is editable after the fact. Find any path that breaks it across steps.
2. **Proposals::Create as it now stands:** the order of halt checks, draft, features (Schwab reads), the lock, the save, the hypothesis drop, the forecast, the evaluation, and the after-commit alert and skeptic. Any Schwab call under the lock, any refusal that loses a halt, any missing audit row.
3. **The triggers:** can anything an existing Phase 2 or 2.5 path writes to order_proposals now be refused? Think of status transitions, evaluations, the expiry sweep, record_shadow!, the allocation planner, and the journal linker.

Report findings by file and line, most severe first, each with a concrete failure scenario and the fix. Under 1,200 words. Say plainly when something is fine.
