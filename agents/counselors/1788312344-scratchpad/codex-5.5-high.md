**Findings**

1. **Must fix: 07:00 brief can beat the 07:00 sync.**  
   `sync_tick` and `agent_morning_brief` both fire at 07:00 ([config/recurring.yml](/Users/jathayde/Development/Personal/desk.athayde/config/recurring.yml:11), [config/recurring.yml](/Users/jathayde/Development/Personal/desk.athayde/config/recurring.yml:17)). `BriefJob#wait_for_sync` only waits for feed rows that are already `running` ([brief_job.rb](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/agent/brief_job.rb:32)), not jobs that are due, enqueued, or about to be enqueued by the tick. On the first real 07:00 run, if the brief job starts first, it can read 06:45/06:55 data and still produce a normal-looking brief. Move the brief later, force/run the required sync first, or require feed success after a 07:00 cutoff before synthesis.

2. **Must fix: memory pull races the morning brief.**  
   `memory_pull_repo` also fires at `*/30`, including 07:00 ([config/recurring.yml](/Users/jathayde/Development/Personal/desk.athayde/config/recurring.yml:26)). The pull job writes a `memory_repo` `SyncRun` ([pull_repo_job.rb](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/memory/pull_repo_job.rb:8)), but the brief waits only on `positions/orders/activities` ([brief_job.rb](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/agent/brief_job.rb:34)). `Memory::Repo#files` reads files directly from the checkout while `git pull --ff-only` may be updating it. Add a shared lock or snapshot the memory files after the pull, and avoid scheduling pull at the same minute as the brief.

3. **Must fix: stale orders are under-reported, making stop/protection text misleading.**  
   `Agent::Context#degraded_reasons` only checks stale positions via `dashboard.balance_stale?` ([context.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/context.rb:27)). `Dashboard#stale_row?` only considers stale orders when `working_stop_order.present?` ([dashboard.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/dashboard.rb:101)). If the orders feed is stale and a position has no assigned stop, the tool can report `unprotected` with `stale: false`; that is exactly when “no stop” may be wrong. Any stop/protection state should depend on orders freshness, including absent stops.

4. **Must fix: fallback market calendar can produce a fake market brief.**  
   `BriefJob` runs whenever `MarketDay.for(date).trading?` is true ([brief_job.rb](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/agent/brief_job.rb:14)). Fallback weekdays are trading days, so a Schwab calendar failure on a holiday can send a degraded but still full market brief. The earlier review called this out: market-day briefs should require Schwab-sourced calendar rows, or send a health-only degraded notice.

5. **Must fix: skipped closed-day runs will be reported as undelivered failures.**  
   Closed days create `skipped` rows with no email ([brief_job.rb](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/agent/brief_job.rb:15)). `AgentRun.unemailed` includes every non-running row with `emailed_at: nil` ([agent_run.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent_run.rb:16)), and the failure digest reports those as “never emailed” ([failure_digest.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/failure_digest.rb:16)). A holiday morning skip will generate a bogus failure digest. Filter out `skipped`, or scope `unemailed` to statuses that should have mailed.

6. **High: Anthropic/client setup errors can bypass the fallback email path.**  
   `Agent::Run.new(run)` evaluates the default `client: Agent.client` before `perform` starts ([run.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/run.rb:15)). If credentials/client construction fails, `BriefJob` leaves the row running until a later sweep and sends no immediate “brief unavailable” email. Inside `perform`, only `Anthropic::Errors::APIError` is handled as non-raising; SDK `ConfigurationError`, `ConversionError`, or local request-shape `ArgumentError` fall into `StandardError`, mark failed, then re-raise ([run.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/run.rb:36)). Wrap runner construction in the job and treat `Anthropic::Errors::Error`/request-shape failures as deliverable failed runs.

7. **High: capped `max_tokens` can email partial prose as a brief.**  
   After the second `max_tokens`, `converse` returns capped with whatever text exists ([run.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/run.rb:58)). The subject says `CAPPED`, but the body can be a cut-off or incomplete market brief. For a financial morning brief, use a deterministic “generation capped; no complete brief” body or require a complete final marker/section before mailing model prose.

**Anthropic Contract Notes**

The SDK-facing request shape looks broadly right for `anthropic` 1.68: `system_`, top-level `cache_control`, `tool_choice: { type: :auto/:none }`, tool `input_schema`, and thinking/tool block round-tripping are supported by the 1.68 types. I could not run `bundle exec gem contents anthropic` or the specs because this sandbox has Bundler 4.0.4 missing and is read-only, so I verified against `Gemfile.lock` and the upstream v1.68.0 SDK source instead.

**Craft Debt**

The fake ignores `tool_choice`, so it will not catch API behavior around “no tools” final turns. Add a real SDK/request-shape spec, preferably `count_tokens` or a VCR/WebMock assertion of the dumped request body.

The Sunday re-auth link requires login; if clicked logged out, the overridden auth redirect intentionally does not preserve return-to, so the user lands at the app after login rather than continuing re-auth. That is safe, but not a one-click ritual.

Sources checked: Anthropic Ruby SDK v1.68.0 `messages`, `tool`, `message`, and `errors` sources on GitHub; Anthropic docs for Claude Sonnet 5 and pricing.
