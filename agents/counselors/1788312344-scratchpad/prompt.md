# Review Request

## Question
Review build step 9 of Phase 1: the scheduled runtime (Solid Queue jobs calling the Anthropic Messages API through the `anthropic` gem 1.68 with the read-only tool registry), the brief and Sunday and failure-digest emails, and the memory repo pull, built to the design you reviewed. Find what breaks on the first real 07:00 run and what would make a brief misleading.

## Context

### Files to Review
Uncommitted on top of commit 1929c46; `git status --porcelain` lists them.
- Runtime: @app/models/agent.rb @app/models/agent/run.rb @app/models/agent/context.rb @app/models/agent/pricing.rb @app/models/agent/fake_anthropic.rb @app/models/agent/prompts/system.md.erb @app/models/agent/prompts/morning_brief.md.erb @app/models/agent/prompts/eod.md.erb @config/initializers/agent.rb
- Rows: @db/migrate/20260902100001_extend_agent_runs.rb @app/models/agent_run.rb
- Memory: @app/models/memory.rb @app/models/memory/repo.rb @app/jobs/memory/pull_repo_job.rb @Dockerfile
- Jobs: @app/jobs/agent/brief_job.rb @app/jobs/agent/morning_brief_job.rb @app/jobs/agent/end_of_day_job.rb @app/jobs/agent/sunday_review_job.rb @app/jobs/jobs/failure_digest_job.rb @config/recurring.yml @lib/tasks/agent.rake
- Email: @app/models/brief.rb @app/models/failure_digest.rb @app/mailers/brief_mailer.rb @app/views/brief_mailer/brief.text.erb @app/views/brief_mailer/brief.html.erb @app/views/brief_mailer/_eod.text.erb @app/views/brief_mailer/_eod.html.erb @app/views/brief_mailer/sunday_review.text.erb @app/views/brief_mailer/sunday_review.html.erb @app/views/brief_mailer/failure_digest.text.erb @app/views/brief_mailer/failure_digest.html.erb
- System page: @app/models/system_status.rb @app/views/system/show.html.erb
- Specs: @spec/models/agent/run_spec.rb @spec/models/agent/context_spec.rb @spec/models/agent/pricing_spec.rb @spec/models/agent_run_spec.rb @spec/models/memory/repo_spec.rb @spec/mailers/brief_mailer_spec.rb @spec/jobs/agent/brief_jobs_spec.rb @spec/jobs/memory/pull_repo_job_spec.rb @spec/jobs/jobs/failure_digest_job_spec.rb
- Supporting (committed): @app/models/agent/tools.rb @app/models/agent/tool.rb @app/models/agent/market_data.rb @app/models/dashboard.rb @app/models/sync_run.rb @app/models/market_day.rb @app/jobs/sync/tick_job.rb

### The design it implements
- @docs/phase-1-plan.md §2 (jobs table, agent_runs row), §3 "Scheduled runtime" and "Briefs as email", §9
- Your previous design review (find the directory by grepping agents/counselors/*/prompt.md for "build step 9")

## Instructions
You are providing an independent review. Be critical and thorough.
- Trace one morning run end to end: recurring task at 07:00 New York, BriefJob (sweep, served?, calendar, wait_for_sync), Agent::Run (system prompt, first call, tool_use handling, parallel blocks, thinking round-trip, caps, every stop reason, usage and cost, the row), BriefMailer (subject, frame, escaping, links), emailed_at
- Verify the request shape against the anthropic gem 1.68 as installed (`bundle exec gem contents anthropic`): `system_:`, top-level `cache_control`, `tool_choice` shapes, `tools` from Agent::Tools.definitions (input_schema key name, `required`, keywords like `format`, `default`, `minItems` that the API may reject), and how model objects in `messages` are serialized on the next call; check what the SDK raises and whether Agent::Run rescues the right classes
- Check the cap semantics: is the last turn really reserved, can the loop spin or exceed MAX_TURNS, does answering a capped batch with is_error results and tool_choice none behave as the API expects, does max_tokens retry drop the right message, can `@text` accumulate thinking or stale partial text
- Check degraded computation and the prompt rules against the PRD's brief contents (5.7) and the earlier review's list of what the model must not infer; check the 07:00 quote and overnight-move wording
- Check idempotency: the partial unique index versus `served?`, `limits_concurrency` keys, a killed worker, a retried job, a resend; the failure digest window and what it double-reports with the nag
- Check the memory repo: file caps and scrub, `safe.directory`, what `pull --ff-only` does on a fresh dokku mount, the Dockerfile change, reading mid-pull
- Check the email frame for anything the model could inject (links, HTML), for dollar figures in subjects, for the EOD sections' correctness (fills today by executed_at in New York, trades touched by updated_at, snapshot by market_date), and for the Sunday review's re-auth link needing login
- Check the specs: what they pin, what they miss (a real Anthropic error shape, the recurring schedule, the fake ignoring tool_choice), and whether the fake stands in faithfully
- Say what must be fixed before this is committed versus what is craft debt
