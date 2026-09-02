# Review Request

## Question
Review the Phase 2 plan for Investment Copilot, @docs/phase-2-plan.md, against the PRD @docs/artifacts/investment-copilot-prd.md (§5.1 idempotency, §5.4, §5.4.1, §5.4.2, §5.5, §5.8, §5.8a, §6, §7, §8, §10) and the UI flows @docs/artifacts/investment-copilot-ui-flows.md (Flows 2, 3, 6, 7), before any Phase 2 code is written. Phase 1 is deployed (@docs/phase-1-plan.md describes what exists: proposals, submission_attempts, and risk_rules tables already exist as shells; the tool registry, audit table, sync, journal, snapshots, and briefs are live). Under 900 words.

## Instructions
Independent and critical. Where does the plan contradict the PRD or the decisions log? Where is the state machine, the idempotent submission path, the guardrail evaluation, the collar, the settled-cash projection, the wash-sale detection, or the write-tool boundary underspecified in a way that will bite? What is the right build order? What Schwab shapes must be verified before step 4, and what can be shadowed safely? What about the plan would make the operator approve something they should not, or let a duplicate order through? Rank by severity; say what must change in the plan before step 1.
