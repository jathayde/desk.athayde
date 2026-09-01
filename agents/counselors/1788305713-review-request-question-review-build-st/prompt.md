# Second Opinion Request

## Question
# Review Request

## Question
Review build step 6 of Phase 1: the trade journal builder, setup stats, and daily snapshots, built to the design you reviewed (plug-leg bootstrap reconciled to the broker, transactional per-activity linking with full recompute from legs, leg cash amounts for P&L, initial quantity from the first order, flows since the prior snapshot, type-first withdrawal classification). Verify the fixes hold in the code and find what will still produce wrong journal rows or drawdown numbers.

## Context

### Files to Review
Uncommitted on top of commit 8970691; `git status --porcelain` lists them.
- @app/models/trade.rb @app/models/journal/linker.rb @app/models/trade_leg.rb @app/models/setup.rb @app/models/snapshot.rb @app/models/activity.rb @app/models/schwab/activity.rb
- @app/jobs/journal/bootstrap_job.rb @app/jobs/journal/link_fills_job.rb @app/jobs/journal/recompute_setup_stats_job.rb @app/jobs/snapshots/daily_job.rb @app/jobs/snapshots/rebuild_job.rb
- Hooks: @app/jobs/sync/positions_job.rb @app/jobs/sync/activities_job.rb @app/jobs/sync/tick_job.rb
- @db/migrate/20260901250001_prepare_journal_columns.rb
- Specs: @spec/models/journal/linker_spec.rb @spec/models/setup_stats_spec.rb @spec/models/snapshot_spec.rb @spec/jobs/journal/hooks_spec.rb @spec/support/journal.rb

### The design it implements
- @docs/phase-1-plan.md §4 and §6
- Your previous design review: @agents/counselors/1788302368-review-request-question-before-build-st/codex-5.5-high.md and claude-fable.md

## Instructions
You are providing an independent review. Be critical and thorough.
- Re-walk each sequence from your previous review against the code: buy/sell; scale in and out; legacy sell-first; bootstrap then the entry fill arriving in the window; 2:1 split via transfer with a stop; dividend mid-trade and after close; reverse merger A to B with a bootstrapped B; same-day out-of-order fills; partial fill on one order. State where the code's rows differ from what you expected
- Trace Trade#recompute! for correctness with adjustment ratios (quantity, avg_entry, initial_risk, total_risk), income legs, and the plug leg sorting first
- Trace reconcile_plug! for: bootstrap before fills, fills before bootstrap, a sell that exceeds the plug, and the plug being deleted at zero; check the LinkFillsJob's second reconcile pass
- Check idempotency and crash safety: the per-activity transaction, journaled_at last, unjournal! on changed activities, the retry on RecordNotUnique in BootstrapJob, two jobs sharing the journal concurrency key
- Check the succession merge in link_corporate_action, including the fallback when one side is missing
- Check Snapshot.build!: balance choice, flows since prior snapshot, share transfers, first snapshot, division by zero, the rebuild range and triggers from both sync jobs, and the tick's snapshot_due?
- Check Setup#recompute_stats! eligibility and the recompute triggers (close, review, exclude)
- Flag missing specs; say which of your earlier concerns are now closed and which remain
- Be direct and opinionated; do not hedge; order by severity with file paths

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
