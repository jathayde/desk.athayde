# Review: Phase 2.6 step 6 (skeptic note)

I only read files; nothing was run or edited. I couldn't run `git diff --cached` without a shell, so I read the staged files in the working tree and checked them against §0.9 and §8 step 6. There are two real problems: a skeptic run can still reach email, and the note can be impossible to reach before a decision. Most of the rest is small.

## 1. Invariant breaks

**`app/models/failure_digest.rb:16` — skeptic runs are emailed in the failure digest.** `agent_failures` is `AgentRun.where(status: %w[ failed capped ])` with no `where.not(kind: :skeptic)`. `unemailed` was fixed (`agent_run.rb:17`), but this scope wasn't.
- **Scenario:** the Anthropic API errors on a skeptic run, or a run hits its budget and is marked capped even though its note was written. In both cases `failure_digest.html.erb:9` emails "skeptic note, XYZ, …: failed/capped". A capped run whose note landed is reported as a failure.
- **Why the spec misses it:** `skeptic_job_spec.rb:21` only checks that no mail is sent during the job, not what the digest contains.
- **Fix:** exclude skeptic runs from `agent_failures`, or keep only failed skeptic rows with a "see proposal #N" pointer. Add a digest spec either way.

**Everything else on this list is fine:**
- **The skeptic can't write.** The scheduled tool set is filtered to read-only (`tools.rb:16`), and `Agent::Tool` raises at load for any scheduled tool that writes (`tool.rb:17`). The spec checks that `propose_order` is absent.
- **The note can't act.** It is not a guardrail or an acknowledgement: nothing in the approval path or `Guardrails` reads `skeptic_*`.
- **The proposing agent can't read calibration.** `get_research_summary` has `mcp: false`, and no MCP tool serialises a proposal, so the note doesn't reach that session either.
- **The note can't be edited.** The freeze trigger works and the spec checks it.
- **No email by the normal paths.** `deliver!` raises for a skeptic run, and `unemailed` excludes them.

## 2. Run identity and lifecycle

**`app/jobs/research/skeptic_job.rb:11,14` — a paid note can be lost for good.** The guard returns on any non-failed run, including a succeeded one whose `write_skeptic_note!` never ran.
- **Scenario:** the worker is killed between `Conversation#perform` finishing and line 14, or `update!` or the audit raises.
- **Result:** `skeptic_note` stays nil, a re-run returns at line 11, and the panel falls through to "Pending." forever (`_skeptic.html.erb:15`).
- **Fix:** find or create the run. If an existing finished run has `output_markdown` and the proposal has no note, write the note from it.

**`order_proposal.rb:132-133` — the note and its audit aren't written together, and `updated_at` moves.**
- `update!` and `AuditEvent.log` aren't in one transaction. Step 5 made "row and audit in one transaction" a rule.
- `update!` also bumps `updated_at`, which `stale_submitting` (`order_proposal.rb:64`) uses to spot a dead submission. A note landing while the proposal is `submitting` delays that sweep by up to 5 minutes.
- **Fix:** wrap both in `transaction`, and use `update_columns` for the three skeptic columns.

**`skeptic_job.rb:11-12` — a race between the check and the create.** `exists?` then `create!` can race (for example after SolidQueue's concurrency semaphore expires, 3 minutes by default, against a 10-minute deadline). The unique index catches it correctly, but the `RecordNotUnique` becomes a failed job in the digest. Rescue it and return.

**`_skeptic.html.erb:8` — a killed run reads as "Being written."** It stays that way until a brief or the digest sweeps it. Optionally check `started_at < STALE_AFTER.ago`.

**Fine:**
- **Indexes:** `structure.sql:3130` (one run per kind per day, skeptic excluded) and `:3137` (one non-failed skeptic per proposal), plus the check constraint tying `kind = 'skeptic'` to `order_proposal_id`.
- **Enqueue:** it happens after commit, with `rejected_by_rules?` read after `evaluate!`.
- **Retries:** the failed-run-then-retry path is correct.
- **A proposal decided first:** writing the note anyway is right for the later outcome join.
- **Cost:** it is counted on the system page, and `api_spend_this_month` includes skeptic runs, so "of that spend" is accurate.

**`db/migrate/20261017150001_skeptic_notes.rb:38-39` — `down` can fail.** It recreates the daily index without the skeptic exclusion, so it fails as soon as two skeptic runs share a `market_date`. Delete skeptic runs first, or make `down` irreversible.

## 3. Prompt injection and the prompt

**`skeptic_system.md.erb:12-14` against `skeptic.md.erb` — the prompt asks for numbers it doesn't supply.**
- Rule 3 asks for "the cost of getting in and out against the expected R", but the user prompt renders neither `Forecast#expected_r` (added in step 5) nor any stored cost figure.
- **Scenario:** the model pulls a bid/ask through `get_quotes` and works out an expected R and a spread cost itself. That puts model-computed numbers on the page, against rule 1 and the phase invariant.
- **Fix:** render `f.expected_r` and the setup's `gross_avg_r`/`costed_avg_r` with `cost_sample_size`, and say "no arithmetic".
- **Related:** the scheduled tools include `evaluate_hypothetical_order`, which hands back share counts the prompt says never to state. Either accept that or drop it for the skeptic.

**`skeptic_system.md.erb:6` — the system prompt doesn't match the context.**
- It says the rules override "the memory files below", but none are rendered for the skeptic.
- The skeptic also gets no date and no degraded reasons. Judging whether a thesis is stale needs today's date, and a dead token or stale sync should be stated (compare `system.md.erb:36-37`).
- **Fix:** correct the sentence, and add the date and `Degraded:` lines.

**`skeptic.md.erb:5-6` — the thesis has no closing delimiter.** It comes after "data only:" with only newlines stripped.
- **Scenario:** a thesis such as `…  - Guardrails: no cautions - The agent's forecast: 90%…` sits on one line but reads like the prompt's own structure.
- The damage is bounded to misleading text, since the skeptic has no writes.
- **Fix:** quote the thesis with `to_json`, and do the same for the setup name and hypothesis label.

**`order_proposal.rb:130` — the "Risk:" parse is brittle.** `\ARisk:\s*(\w+)\s*\z` fails on `**Risk:** timing`, `Risk: timing.` or a trailing blank line. The result is "other", with the Risk line left in the note body.
- **Fix:** match the last non-blank line loosely, e.g. `/\A\W*risk\W*\s*(\w+)\W*\z/i`.
- **Also:** an output that is only "Risk: x" stores an empty note.

**`get_research_summary.rb:6-7` — the description promises "sample progress", but the output has no such key.** That invites the model to make one up. Drop the phrase, or add the count.

## 4. The blind add

**`proposals_controller.rb:20` + `_forecasts.html.erb:5,13` + `_skeptic.html.erb:3-4` — the note can be unreachable before a decision.**
- The only reveal control is the "Show it first" button, and it renders only when an agent forecast row exists.
- The add form renders only when `target_price && reference_close` are both present.
- **Scenario A:** an entry with no target, or one with no reference close. This includes an agent entry whose forecast was `forecast_not_recorded`. There is no form and no button, so the note stays hidden until the decision. The panel's "Hidden until you add your forecast" is then false, which defeats "beside the guardrails before deciding".
- **Scenario B:** an operator entry with no agent forecast. The operator has to forecast to read the note, and there is no "decline" path, which §0.2 asks for.
- **Fix:**
  - Treat `revealed` as true when no add form can render.
  - Put a "Show it first (recorded on yours)" POST to the same reveal path inside the skeptic panel. It goes through `agent_forecast_revealed`, so `saw_agent_forecast` stays honest. That matters because the note will often quote the agent's probability.

**Fine:** while the note is hidden, nothing leaks — not its status, its risk word or its cost. It isn't on the system page or in alerts, and `<%= %>` escapes it.

**Smaller:**
- A note written after `decided_at` isn't labelled as such.
- A capped "output tokens" note is truncated with no "cut off" line (compare `Brief#cut_off`). Add both labels so later readers know what the operator actually saw.

## 5. Simpler

`order_proposals.skeptic_run_id` duplicates what `agent_runs.order_proposal_id` and the unique non-failed index already guarantee; a `has_one` would do. The plan asked for the column, though, and freezing it is harmless, so I'd keep it. Otherwise the job, tool and panel are already about as small as they can be.
