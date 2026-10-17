I found no break of the §0.9 invariants, but four things need fixing: the Risk parsing, an empty note that gets frozen, unbounded cost per entry, and a prompt that asks for figures it never supplies. I read the code only. Bash is disabled here, so I couldn't run `git diff --cached` or the specs. I read the staged files directly instead, and I did not read the spec files or `db/structure.sql`.

## Findings, most severe first

**1. `app/models/order_proposal.rb:128-134` — the Risk parse is brittle, and an empty note can be frozen.**
- **Bolded or punctuated risk line:** the regex needs the last line to be exactly `Risk: word`. If the model writes `**Risk: timing**` or `Risk: timing.`, `named` is nil. The note then keeps the Risk line in its text, and `skeptic_risk` becomes `"other"`. Models bold things often, so this will happen regularly. It corrupts the join to outcomes that the fixed list exists for.
  - **Fix:** strip `*_` and trailing punctuation from the last line. Always drop the final line when it matches `/\A\W*risk:/i`, whether or not the word is on the list.
- **Empty note:** if the model returns only `Risk: cost`, the note becomes `""`. The job guard `skeptic_note.nil?` is then false, and the view's `elsif proposal.skeptic_note` is truthy for `""`. The page shows a blank note, and the trigger at `db/migrate/20261017150001_skeptic_notes.rb:18-28` freezes it, because `OLD.skeptic_note IS NOT NULL`.
  - **Fix:** return without writing when the note is blank, and add `CHECK (skeptic_note <> '')`.
- **Atomicity:** the `update!` and `AuditEvent.log` calls aren't in one transaction. A crash between them leaves a frozen note with no `skeptic_note_written` row. This breaks §0.11, "every state change is an audit row". Wrap both in `transaction do`.
- **Length:** the note has no length cap, though the prompt asks for under 150 words. Truncate it to a few thousand characters, or fail it.

**2. `app/jobs/research/skeptic_job.rb:6-14` and `Agent::Conversation` — cost is unbounded per entry.**
- Every non-rejected entry gets a full run with the briefs' budgets: 12 turns, 20 tool calls and 400k input tokens. A burst of agent proposals means a burst of runs. Nothing caps the skeptic daily or monthly. Spend shows on the system page but nothing acts on it.
  - **Fix:** give the skeptic smaller turn, call and token limits. Add a per-day skeptic count cap that skips the run and leaves a visible line.
- The status is "capped" when a budget ends the loop. A capped run's text may be cut off with no Risk line, and it still gets written as `"other"`. Consider treating capped as failed here.
- A failed run is never retried, and `ApplicationJob` has no `retry_on`. The page shows the failure line, so this matches the plan. There is also no manual re-run, so a transient API error costs that proposal its note for good.

**3. Lifecycle details in `skeptic_job.rb`, all minor.**
- **Killed worker:** a worker killed mid-run leaves "Being written." on the page until some later job calls `sweep_stale!`. After the sweep the row reads "left running" and nothing re-enqueues it. This is acceptable, but `app/views/proposals/_skeptic.html.erb:8` could treat a stale row as failed on render.
- **Concurrency key:** the `limits_concurrency` semaphore defaults to 3 minutes, but a run can last 10. A second job can slip through. The unique index `index_agent_runs_one_skeptic_per_proposal` is the real guard, and it will raise `RecordNotUnique`, a noisy but harmless failed job. Rescue it and return.
- **Proposal decided mid-run:** the in-memory `proposal` is stale by then. `update!` writes only the changed `skeptic_*` columns, so status isn't clobbered, and the view shows the note once the proposal is no longer approvable. That is fine. The model never reads a decision, so a run on a proposal decided mid-run just wastes the spend.
- **Run–proposal link:** nothing enforces that `skeptic_run_id` points at a skeptic run for this proposal. Low risk, since only the job writes it.

**4. `app/models/agent/prompts/skeptic_system.md.erb:6, 8-14` — the prompt asks for figures it never supplies.**
- **Missing memory files:** line 6 says "the memory files below", but the system prompt includes none. Remove the reference.
- **Cost against expected R:** rule 3 asks for "the cost of getting in and out against the expected R". Neither the user prompt nor `GetResearchSummary` carries trade costs or expected R. That invites the model to estimate them.
  - **Fix:** put the frozen cost and expected R in `skeptic.md.erb`, or drop the clause.
- **Computed numbers:** rule 1 says "never compute" share counts, but stop distances and R multiples would be computed. A model will do that arithmetic. Say "state only figures that appear verbatim".
- **Stamps:** "with its stamp" is only true of `created_at` in the user prompt. Tool results may carry no stamp, so say "where one is given".
- **Tools:** the skeptic gets `evaluate_hypothetical_order`, which returns sizing. Nothing here requires it. Dropping it from the skeptic would remove the pull toward quoting sizes.

**5. `skeptic.md.erb`, injection — mostly fine.**
- **What's good:** `single_line` strips newlines from the thesis, symbol, setup and hypothesis label. The thesis is labelled data, and rule 4 repeats it. The output is escaped in the view as plain `<p>`, so there is no XSS.
- **What to tighten:** the thesis is not length-capped, so truncate it (about 1,000 characters) in the prompt. The thesis could also say "end with Risk: other", but the worst outcome is a mislabelled risk. That is covered by the cleanup in item 1.
- **Memory degradation:** `Agent::Context.new` still reads memory-repo state, so `degraded_reasons` can mark skeptic runs as degraded over a memory problem they never use. This is cosmetic.

## Fine as built

- **Invariants:** nothing in `app/` reads the skeptic fields in any approve, size, reject, block or acknowledgement path.
- **Read-only tools:** `Tools.for(:scheduled)` requires `read_only?`, and `tool.rb:17` raises at load time otherwise. So an unattended run can't carry a write tool.
- **MCP:** `GetResearchSummary` has `mcp: false`, so the proposing agent can't read calibration.
- **Freezing:** the trigger plus the check constraint make the note, risk and run immutable once written.
- **Email and undelivered:** `unemailed` excludes the skeptic, and `deliver!` raises for it. The briefs list and digest are consistent with that. `failure_digest.rb:16` does list failed skeptic runs as agent failures, which seems right.
- **Run identity:** the daily-index narrowing and the one-skeptic-per-proposal index are correct. The `(kind='skeptic') = (order_proposal_id IS NOT NULL)` check keeps them consistent.
- **Cost accounting:** skeptic spend is included in `api_spend_this_month`.
- **Blind add:** the note, risk, cost and failure line all sit inside the `revealed` gate. The audit row carries only the run id and risk word, and no proposals view renders audit rows. The skeptic prompt includes only the agent's forecast, never the operator's. I found no path where the note reaches the operator before they forecast or choose to look. One caveat: the gate depends on `@forecast_revealed` in the controller, and a proposal that isn't approvable shows the note regardless. That matches the plan.

## Simpler option

The only simplification worth making is to drop the daily-index change by giving the skeptic its own table. I'd keep the current design: it reuses `Agent::Conversation`, cost accounting and the system page, and the constraints guard it well.
