# Second Opinion Request

## Question
# Review Request

## Question
Review build step 3 of Phase 1: the Schwab adapter layer (HTTP client, OAuth calls, error taxonomy, scrubbing, rate budget, typed mappers, fake client, fixtures). Check it against the contract it was built to, and look for bugs that would only show up against the real API or under concurrency.

## Context

### Files to Review
Uncommitted on top of the step 2 commit; `git status --porcelain` lists them.
- @app/models/schwab.rb @app/models/schwab/client.rb @app/models/schwab/error.rb @app/models/schwab/timestamp.rb @app/models/schwab/scrub.rb @app/models/schwab/decimal.rb @app/models/schwab/rate_budget.rb
- Mappers: @app/models/schwab/instrument_ref.rb @app/models/schwab/position.rb @app/models/schwab/balances.rb @app/models/schwab/account_summary.rb @app/models/schwab/order.rb @app/models/schwab/activity.rb @app/models/schwab/market_hours.rb @app/models/schwab/quote.rb @app/models/schwab/price_history.rb
- @app/models/schwab/fake_client.rb and fixtures under @lib/schwab_fixtures/
- @config/initializers/schwab.rb
- Specs: @spec/models/schwab/client_spec.rb @spec/models/schwab/mappers_spec.rb @spec/models/schwab/fake_client_spec.rb @spec/models/schwab/timestamp_spec.rb @spec/models/schwab/scrub_spec.rb @spec/models/schwab/error_spec.rb @spec/models/schwab/rate_budget_spec.rb @spec/schwab_isolation_spec.rb

### The contract it implements
- @docs/schwab-api-contract.md (compiled from your previous review; the adapter should match it)
- @docs/verify-on-approval.md
- @docs/phase-1-plan.md §2 "Schwab client" paragraph

## Instructions
You are providing an independent review. Be critical and thorough.
- Check every endpoint method against the contract: path, params, formats, headers, response handling
- Check the OAuth methods: Basic auth, form encoding, the `@` in the code, `id_token` dropped, 4xx from the token endpoint as ReauthRequired
- Check the retry loop for correctness: which statuses retry, backoff and jitter, Retry-After cap, no retry on 4xx, transport errors, the idempotent/non-idempotent split, attempt counting, and whether the 401 refresh-and-retry can loop or double-refresh under concurrent jobs
- Check that the rate budget is actually shared across processes given Rails.cache (Solid Cache in production, memory store in test/dev) and that increment semantics are right
- Check scrubbing: is any plaintext account number path missed (error bodies, exceptions, log lines, the FakeClient fixtures)
- Check each mapper against the contract shapes and the failure modes: missing CUSIP, missing time, unknown enums, nested orders lineage, fee summation and side derivation on activities, closed-day market hours, quotes errors key, candle dates
- Check the FakeClient: interface parity, scenario scripting sufficiency for steps 4 through 7 (re-auth success/failure, expired token, rate limit, server error, timeout, removed position, closed market)
- Flag missing specs, and anything the isolation spec would not catch
- Be direct and opinionated; do not hedge; order findings by severity with file paths

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
