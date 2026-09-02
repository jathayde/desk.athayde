# Second Opinion Request

## Question
# Review Request

## Question
Review build step 7 of Phase 1: the dashboard, system, and journal screens, the model prerequisites they needed, and the Playwright harness. Built to the design you reviewed; verify the fixes hold and find what a user will hit on the phone that the specs did not.

## Context

### Files to Review
Uncommitted on top of commit 9ce61b4; `git status --porcelain` lists them.
- @app/models/dashboard.rb @app/models/playwright/scenario.rb @app/models/schwab_token.rb @app/models/account.rb @app/models/trade.rb @app/models/position.rb @app/models/schwab/position.rb @app/jobs/sync/positions_job.rb @app/jobs/sync/tick_job.rb @app/jobs/schwab/token_health_job.rb
- @app/controllers/dashboard_controller.rb @app/controllers/system_controller.rb @app/controllers/accounts_controller.rb @app/controllers/trades_controller.rb @app/controllers/playwright/scenarios_controller.rb
- @app/views/dashboard/show.html.erb @app/views/dashboard/_banner.html.erb @app/views/system/show.html.erb @app/views/trades/index.html.erb @app/views/trades/show.html.erb @app/views/trades/review.html.erb @app/views/layouts/application.html.erb @app/helpers/application_helper.rb @app/helpers/dashboard_helper.rb
- @config/routes.rb @config/ci.rb @config/database.yml @bin/playwright @playwright.config.js @e2e/dashboard.spec.js @e2e/review.spec.js @e2e/system.spec.js
- Specs: @spec/models/dashboard_spec.rb @spec/requests/dashboard_spec.rb @spec/requests/system_spec.rb @spec/requests/trades_spec.rb

### The design it implements
- @docs/phase-1-plan.md §7 and §8
- @docs/artifacts/investment-copilot-ui-flows.md Flows 1, 4, 8 and the cross-cutting states
- Your previous design review: @agents/counselors/1788302937-review-request-question-before-build-st/codex-5.5-high.md and claude-fable.md (find the directory by grepping prompt.md for "build step 7" if that id is wrong)

## Instructions
You are providing an independent review. Be critical and thorough.
- Check every banner and status-line rule in Dashboard against the states: no token, revoked, expired, expiring covered or not by Sunday, halted with and without a token problem, sync paused for a non-token reason, a failed sync with a usable token, fallback calendar, needs setup, no trading account, waiting for the first sync
- Check the staleness rule and the as-of choice per row (positions synced_at versus the orders run finish) against plan §7
- Check the day change: prior snapshot by date, flows since it, the first-day state, and the label
- Check the review flow on the phone: queue order, Skip persistence, Save with a new setup name, the stop validation copy, the closed-legacy case, Not a setup trade, and what the next-in-queue redirect does at the end
- Check the system page: halt and resume auditing and confirmation, the accounts form (nickname, type, enable) and its validation, the feeds table, failures, honest not-yet rows
- Check the Playwright scenarios route guard, the scenario seeds for realism and isolation (separate TEST_DATABASE), the e2e assertions for brittleness
- Check for N+1 queries on the dashboard and journal pages, and anything that would break under Hotwire Native (confirms, hover, page-level JS)
- Flag missing specs and anything the request specs assert too weakly
- Be direct and opinionated; do not hedge; order by severity with file paths

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
