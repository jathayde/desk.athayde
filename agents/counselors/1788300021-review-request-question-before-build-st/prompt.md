# Second Opinion Request

## Question
# Review Request

## Question
Before build step 4 (Schwab OAuth flow and the token lifecycle) is written, review the design against the PRD and find what would go wrong operationally. This is the top operational risk in the PRD: a missed re-auth silently kills all automation.

## Context

### PRD and plan sections
- @docs/artifacts/investment-copilot-prd.md §5.1 (OAuth, 25-minute refresh, 7-day expiry, degrade-and-queue, re-auth flow), §5.10 (Sunday ritual, Mon/Tue escalation), §10 (risks)
- @docs/artifacts/investment-copilot-ui-flows.md Flow 1 banner states (token expiring / token expired), Flow 5 re-auth success and failure, Flow 8 token age
- @docs/phase-1-plan.md §2 (token gating paragraph and the `Schwab::RefreshAccessTokenJob`, `Schwab::TokenHealthJob`, `Sync::CatchUpJob` rows), §7 (re-auth and login rows), §0 decisions 3 and 8
- @docs/schwab-api-contract.md OAuth section (authorize URL, callback with `@` in the code, token response, lifetimes, refresh does not extend the 7-day window, token-endpoint 4xx means re-auth)

### What exists
- Step 1: magic-link login, two seeded users, `Authentication` concern with `Current.user`.
- Step 2: `schwab_tokens` table (access_token and refresh_token encrypted, access_expires_at, refresh_expires_at NOT NULL and never moved by a refresh, issued_at, last_refreshed_at, last_refresh_error, scope), `audit_events` with `AuditEvent::KINDS` including re_auth_succeeded, re_auth_failed, token_refresh_failed, sync_paused_token_expired, sync_resumed, token_nag_sent; `system_settings.sync_paused_reason`; `sync_runs`.
- Step 3: `Schwab::Client#authorize_url(state:)`, `#exchange_code(code)`, `#refresh(refresh_token)`; the client calls `token.refresh!` once on a 401 if the token object responds to it; `Schwab::ReauthRequired` for any token-endpoint 4xx; `Schwab::FakeClient` with a fake authorize URL and a scripted code exchange. See @app/models/schwab/client.rb and @app/models/schwab/fake_client.rb.

### Planned step 4 design
- `SchwabToken.current` (latest row). Predicates: `access_expired?`, `refresh_expired?`, `refresh_expiring_within?(24.hours)`, `usable?`. `SchwabToken.issue!(token_response)` on code exchange: new row, `issued_at` now, `refresh_expires_at` = issued_at + 7 days. `SchwabToken#refresh!`: calls the client's refresh grant under a row lock so two jobs cannot double-refresh; updates access token and `access_expires_at`, stores whatever refresh_token comes back, never touches `refresh_expires_at`; on `ReauthRequired` records `last_refresh_error`, audits `token_refresh_failed`, and pauses sync via `system_settings.sync_paused_reason`.
- `Schwab::RefreshAccessTokenJob` every 25 minutes (recurring.yml): no-op if no token or refresh expired; otherwise `refresh!`.
- `Schwab::TokenHealthJob` daily 08:00 and 20:00 ET: nag email when `refresh_expires_at` < now + 24h; on Monday and Tuesday also nag if `refresh_expires_at` is before the coming Sunday 18:00 email plus 12h buffer; audits `token_nag_sent`.
- `SchwabController`: `authorize` (requires login; stores a random `state` in the session; redirects to `authorize_url`), `callback` (requires login; verifies `state`; `exchange_code(params[:code])`; `SchwabToken.issue!`; audits `re_auth_succeeded`; clears the pause and enqueues `Sync::CatchUpJob`; renders success with the new expiry), failure renders the error with a retry link and audits `re_auth_failed`. A `fake_authorize` route exists only for the fake adapter and redirects to the callback with the fake code.
- `TokenGated` concern for jobs: skip and record `skipped_token` when the refresh token is expired.
- Dashboard banner precedence uses these predicates (built in step 7).

## Instructions
You are providing an independent review. Be critical and thorough.
- Check the design against every requirement in §5.1 and §5.10, and the callback against the contract (state echo unverified, code decoding, exact redirect_uri match)
- Find race conditions: two workers refreshing at once, a refresh landing during the code exchange, the callback hit twice, a refresh running while the token row is being replaced
- Check the clock math: 30-minute access token with a 25-minute refresh under Solid Queue scheduling drift, 7-day expiry from issuance, the Mon/Tue escalation rule, time zones
- Check the failure paths: token endpoint 5xx versus 4xx, transport errors, a refresh that returns a different refresh_token string, what the user sees when re-auth fails, what happens if the user completes re-auth while jobs are mid-run
- Check security: login required on both routes, state as CSRF, session fixation on the callback, the token never appearing in logs or the URL, whether the fake_authorize route can ever be reachable in production
- Flag anything missing for Phase 2 (the submission path will need the token too)
- Be direct and opinionated; do not hedge; order by severity

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
