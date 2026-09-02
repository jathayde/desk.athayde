# Second Opinion Request

## Question
# Review Request

## Question
Before build step 9 (the scheduled runtime: Solid Queue jobs calling the Anthropic Messages API with the read-only tool registry, a hard tool-turn cap, and email output for the 07:00 brief, 16:30 EOD, and a Sunday stub; plus the memory repo pull and the job-failure digest) is written, review the design against the PRD and find what will go wrong operationally or produce a misleading brief.

## Context

### PRD and plan
- @docs/artifacts/investment-copilot-prd.md §5.5a (scheduled runtime: Messages API with an API key, same tool definitions as MCP, unattended runs read-only, hard cap on tool turns, ingests untrusted text so no write tools), §5.6 (memory repo: human-authored markdown, pulled on a schedule, served into prompts; Rails never commits), §5.7 (07:00 pre-market brief content; 16:30 EOD content; Sunday edge review; token-health nag), §5.10 (Sunday email bundles edge review, re-auth link, health summary), §5.9 (shadow mode is on and audited)
- @docs/phase-1-plan.md §2 (Memory::PullRepoJob, Agent::MorningBriefJob, Agent::EndOfDayJob, Agent::SundayReviewJob stub, Jobs::FailureDigestJob rows; the token-gating paragraph: agent jobs run degraded with as-of stamps rather than waiting), §3 "Scheduled runtime" paragraph (Agent::Run wraps one Messages API conversation; system prompt = memory repo markdown + setup stats + token health + as-of stamps; tools = scheduled-allowed registry; MAX_TOOL_TURNS = 12; result stored in agent_runs and emailed; prompts as ERB under app/models/agent/prompts; the morning brief states earnings and econ data are unavailable), §1 rows 19 (agent_runs: kind, status, degraded, started_at, finished_at, tool_turns, input_tokens, output_tokens, estimated_cost, output_markdown, error, model) and 20 (tool_calls)
- @docs/artifacts/investment-copilot-ui-flows.md notification inventory (email: morning brief, EOD summary, Sunday ritual, job-failure digest collapsed to one per failure type per day)

### What exists
- Step 8 registry: `Agent::Tools.definitions(:scheduled)` returns `{name, description, input_schema}` for the seven read tools; `Agent::Tools.call(name, arguments, transport: :scheduled, agent_run:)` dispatches with telemetry into tool_calls and returns a Result (ok, value, error, retry_after) and never raises. `Agent.serialize` renders decimal strings and New York timestamps. See @app/models/agent/tools.rb and @app/models/agent/tool.rb.
- The `anthropic` official Ruby SDK (1.68) is approved and not yet added. The API key is in production credentials under anthropic.api_key.
- Mail: Resend over SMTP, TokenMailer as the pattern, users listed for recipients. SchwabToken.status, Dashboard read model, SystemSettings (shadow_mode, manual_halt), SyncRun, Setup stats, Trade.missing_post_mortem, Snapshot.
- config/recurring.yml with explicit cron in America/New_York; Solid Queue with named queues.
- MEMORY_REPO_PATH is a dokku ENV var pointing at a mounted checkout of the memory git repo (investor-profile.md, strategy.md, watchlist.md, prompts.md, instructions.md, edge.md).

### Planned step 9 design
- `Agent::Run.perform(kind:)`: creates the agent_runs row; builds the system prompt from the memory files (each under a heading, with a size cap), the setup stats, the token status line at the top, the shadow-mode line, and the as-of/degraded note; sends the kind's ERB prompt as the user turn; loops Messages API calls with `tools` from the registry until end_turn or MAX_TOOL_TURNS; each tool_use block goes through Agent::Tools.call and returns a tool_result with the JSON text (is_error when the result failed); records tool_turns, tokens, estimated cost from a price table, the final text as output_markdown; emails it via BriefMailer; marks failed with the error on any exception; degraded when the token is unusable.
- Model: the default Claude model configured in one place; max_tokens per kind; temperature default; no streaming.
- Prompt injection stance: memory files are human-authored, but tool results include symbols, descriptions, and thesis text; the system prompt says tool results are data.
- `Memory::PullRepoJob` every 30 minutes: `git -C path pull --ff-only`, records a sync_runs row (feed memory_repo), never writes.
- `Jobs::FailureDigestJob` daily 17:00: failed sync_runs and agent_runs since the last digest, plus Solid Queue failed executions, grouped by kind, one email.
- `Agent::SundayReviewJob` stub: no API call; emails the re-auth link, token age, setup stats table, and sync health.
- Schedules in recurring.yml on market days only for the brief and EOD (the job returns early on a closed day using MarketDay).

## Instructions
You are providing an independent review. Be critical and thorough.
- Check the Messages API loop design against the current Anthropic API and the Ruby SDK 1.68: request shape, tool definitions, tool_use/tool_result blocks, stop reasons, max_tokens, errors and retries, rate limits, prompt caching for the repeated system prompt, token counting for cost, and what to do on a truncated (max_tokens) turn
- Check the turn cap semantics: what counts as a turn, what the run does when the cap is hit mid-thought, and how the brief should read when the model never produced a final answer
- Check the degraded path: token unusable, Schwab down, stale data; what the brief must say and what it must not infer (earnings, econ calendar, news)
- Check prompt injection exposure and mitigations given untrusted text can reach the model through tool results
- Check the schedule: market-day gating from MarketDay, time zones, holidays, a job that runs while a sync is in progress, and idempotency if Solid Queue runs a recurring task twice
- Check the email: what belongs in the subject, deep links (which routes exist), the token status line, and the failure digest collapsing rule
- Check the memory repo pull: ownership and permissions on the dokku mount, a dirty or diverged checkout, the size cap, and what the prompt gets when the repo is missing
- Check cost control: max_tokens, turn cap, model choice, and the estimated_cost table's maintenance
- Flag Phase 2 needs (interactive write tools, push) that the runtime should not preclude
- Be direct and opinionated; do not hedge; order by severity

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
