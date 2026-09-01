# Second Opinion Request

## Question
# Review Request

## Question
Review build step 4 of Phase 1: the Schwab OAuth round trip and token lifecycle, built to the design you reviewed earlier (your findings on the Monday/Tuesday escalation rule, stale-row pauses, callback idempotency, and account binding were all incorporated). Verify the fixes actually hold, and find what is still wrong.

## Context

### Files to Review
Uncommitted on top of the step 3 commit; `git status --porcelain` lists them.
- @app/models/schwab_token.rb @app/models/schwab_token/reauth.rb @app/models/schwab.rb
- @app/controllers/schwab_controller.rb @app/views/schwab/connected.html.erb @app/views/schwab/failed.html.erb @app/views/schwab/nothing_pending.html.erb
- @app/jobs/schwab/refresh_access_token_job.rb @app/jobs/schwab/token_health_job.rb @app/jobs/sync/catch_up_job.rb
- @app/mailers/token_mailer.rb
- @config/recurring.yml @config/queue.yml @config/routes.rb @config/initializers/filter_parameter_logging.rb @config/initializers/schwab.rb
- @db/migrate/20260901230001_add_revoked_at_to_schwab_tokens.rb
- Specs: @spec/models/schwab_token_spec.rb @spec/jobs/schwab/token_health_job_spec.rb @spec/jobs/schwab/refresh_access_token_job_spec.rb @spec/requests/schwab_spec.rb
- Supporting, from earlier steps: @app/controllers/concerns/authentication.rb @app/models/schwab/client.rb (the 401 refresh-and-retry calls token.refresh!) @app/models/schwab/fake_client.rb

### The design it implements
- @docs/phase-1-plan.md §2 paragraphs "Token model", "Token gating", "Re-auth flow", "Health and nags"
- @docs/artifacts/investment-copilot-prd.md §5.1, §5.10
- Your previous review: @agents/counselors/1788300021-review-request-question-before-build-st/codex-5.5-high.md and claude-fable.md

## Instructions
You are providing an independent review. Be critical and thorough.
- Re-derive the Monday/Tuesday rule from the code and check it against: re-auth Sunday 18:30 then Monday 08:00 (no nag), re-auth Wednesday then next Monday (nag), token issued Sunday 17:00 before the email (edge case), DST transitions
- Trace refresh! for: two processes hitting 401 at once; a refresh in flight when issue! inserts a new row; a ReauthRequired on a stale row; a ServerError; a response missing refresh_token; whether the rescue outside with_lock can observe rolled-back state; whether the debounce can suppress a needed refresh after a failed one
- Trace the callback for: the double hit, the browser refresh after redirect, a forged state, an expired state, the user cancelling, an unauthenticated hit, the account-binding check on first auth versus later auth, whether any path writes a token on failure
- Check what leaks into logs (the callback path with code and state, the mailer body, exception messages containing token responses)
- Check Schwab.client's NoUsableToken and the fake_authorize guard against production
- Check recurring.yml and queue.yml against Solid Queue's actual syntax for schedules, time zones, and queue priority
- Flag missing specs and anything the specs assert too weakly
- Be direct and opinionated; do not hedge; order findings by severity with file paths

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
