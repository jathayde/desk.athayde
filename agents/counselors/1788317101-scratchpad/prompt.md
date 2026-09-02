# Review Request

## Question
Narrow phase-level review of Investment Copilot Phase 1 (Rails 8.1, all steps committed on `main`) before the first production deploy. Two questions only, read the named files only, and answer in under 600 words:
1. Cross-layer contracts: does what sync writes match what the journal, snapshots, Dashboard, and agent tools read? Look for one rule written two ways (staleness, statuses, as-of stamps, plug legs and ratios, cash flows, protection states) and say which layer is wrong.
2. The 7-day token ritual end to end, with the token unusable mid-week: what each layer does during the pause (sync, snapshots, dashboard, MCP tools, morning and EOD briefs, the digest), and where the operator would be misled.

## Files
@app/jobs/sync/positions_job.rb @app/jobs/sync/orders_job.rb @app/jobs/sync/activities_job.rb @app/jobs/sync/tick_job.rb @app/models/sync_run.rb @app/models/schwab_token.rb @app/models/position.rb @app/models/trade.rb @app/models/journal/linker.rb @app/models/snapshot.rb @app/models/dashboard.rb @app/models/agent/context.rb @app/models/agent/run.rb @app/models/brief.rb @app/jobs/agent/brief_job.rb @app/models/failure_digest.rb
Design: @docs/phase-1-plan.md §2, §4, §5, §6, §7 (skim).

## Instructions
Independent, critical, specific (file:line). Rank by severity, before-deploy versus later. Do not run the suite.
