# Review request: Phase 2.6 step 6 (skeptic note)

Review the staged change (`git diff --cached`) against `docs/phase-2.6-plan.md` (§0.9, §4 step 6, §8 step 6). Read-only: do not edit or run anything that writes.

Look for, in order:
1. **Invariant breaks:** the skeptic able to place, size, approve, reject, block, or change a proposal; the note becoming a guardrail or an acknowledgement; an unattended run with a write tool; the proposing (MCP) agent able to read calibration; a note editable after it is written; a skeptic run emailed or counted as undelivered.
2. **The run's identity and lifecycle:** the agent_runs index change (one per kind per day except skeptic; one skeptic per proposal), stale running rows, retries after a failure, concurrency, a proposal decided before the note arrives, cost accounting.
3. **Prompt injection and the prompt itself:** the thesis and other free text reaching the model as data; anything in `app/models/agent/prompts/skeptic*.md.erb` that invites invented numbers, sizes, or earnings dates; the "Risk:" parsing.
4. **The blind add:** can the note anchor the operator's forecast?
5. Anything simpler that does the same.

Report findings by file and line, most severe first, each with a concrete failure scenario and the fix. Say plainly when something is fine.
