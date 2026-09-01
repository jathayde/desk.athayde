**Verdict**

The planned step 4 is close on the happy path, but it is not operationally safe yet. The main failure mode is not just “token expires”; it is “an old token actor changes global system state after a newer re-auth succeeded.” That can silently pause automation even though the user did the right thing.

**Critical Issues**

1. **Old refresh jobs can pause sync after successful re-auth.**

A refresh job may load token row A, then the user completes re-auth and `issue!` creates token row B. If the old refresh later receives a token-endpoint 4xx, the planned `refresh!` pauses sync globally via `system_settings.sync_paused_reason`.

That is the exact operational failure the PRD is trying to avoid: valid current token, automation paused anyway.

Required fix: every refresh failure path must check “am I still the current token?” before writing global pause state or health state. Use a token epoch/current-token guard, not just `SchwabToken.current` informally.

Best pattern:
- Add an explicit `active` boolean or `token_generation`.
- Enforce one active token with a partial unique index.
- `issue!` atomically deactivates old rows and activates the new row.
- `refresh!` may update/audit/pause only if its row is still active at commit time.

2. **Two refresh workers can still double-refresh unless the lock reloads and rechecks.**

A row lock is necessary but not sufficient. If two jobs enter, the second must reload inside the lock and skip if the first already refreshed recently. Otherwise it may immediately reuse the newly returned refresh token or, worse, a stale token captured before the lock.

Required fix:
- Build the Schwab client inside the lock, after reload.
- Recheck `access_expires_at`.
- Return early if the token is no longer active or no longer near expiry.
- Never capture `refresh_token` before the lock.

3. **The Mon/Tue escalation rule is mathematically wrong as written.**

The phase plan says Monday/Tuesday nag if `refresh_expires_at` is before the coming Sunday 18:00 email plus 12h buffer. A token issued Sunday evening can never survive until the following Monday 06:00, so this rule will nag even after a successful Sunday re-auth.

This conflicts with the PRD’s Sunday ritual in [investment-copilot-prd.md](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md:211).

Required fix: define escalation in terms of whether the last Sunday ritual was completed, not whether the token survives past next Sunday plus 12h. For example:
- Sunday email always includes re-auth.
- Monday/Tuesday escalation fires if `issued_at < most_recent_sunday_18_et`.
- T-24h nags remain separate.

4. **Refresh-token expiry must be treated as duration, not calendar math.**

Schwab’s refresh token is valid for 7 elapsed days. Do not use wall-clock “7 days” semantics across DST. Use `168.hours` from issuance, and use a safety margin when making decisions.

Also, `access_expires_at` should be `expires_in.seconds.from_now - safety_margin`, not the exact 30-minute value. A 25-minute recurring job leaves too little room for Solid Queue delay, retries, `Retry-After`, deploy restarts, or a stuck worker.

5. **Callback idempotency is missing.**

A browser refresh, double click, back button, or retry can hit the callback twice. The second hit will likely produce `invalid_grant`, causing a visible failure and a `re_auth_failed` audit immediately after success.

Required fix:
- Consume OAuth state exactly once.
- Bind state to user/session.
- On duplicate callback after success, show the already-successful token result instead of auditing failure.
- Delete the session state before exchange, but persist enough state server-side to distinguish duplicate success from attack/failure.

**High-Risk Gaps**

6. **Transport/5xx refresh failures are not a re-auth problem, but they still break automation.**

The contract says token-endpoint 4xx means re-auth; 5xx and transport errors are retried. After retries fail, the planned design does not say what jobs see.

Required behavior:
- Do not pause as “re-auth required” on 5xx/transport.
- Record `last_refresh_error`.
- Alert if repeated or near refresh expiry.
- If access token is expired and refresh cannot be obtained, scheduled sync must degrade/queue visibly instead of repeatedly failing.

7. **`TokenGated` is too blunt.**

The PRD says scheduled work degrades gracefully and queues; the phase plan says only `Sync::TickJob` writes hourly `skipped_token`, agent jobs run degraded, and no queue growth occurs.

A generic concern that “skips jobs when refresh expired” risks silent loss and duplicate skip rows. Token gating should be role-specific:
- Sync tick: records one skipped episode/hour and enqueues nothing.
- Agent jobs: run degraded with stale timestamps.
- Catch-up: runs only after current valid token.
- Phase 2 submission: hard-blocks with re-auth required.

8. **Unauthenticated callback handling can leak or preserve the OAuth code.**

The default authentication concern stores `request.url` as `return_to_after_authenticating`. If `/schwab/callback?code=...` is hit unauthenticated, the code can be stored in session and appear in app/request logs unless filtering is explicit.

Required fix:
- Callback should reject unauthenticated access without storing return-to.
- Add parameter filtering for `code`, `access_token`, `refresh_token`, `id_token`.
- Never include raw Schwab errors, codes, tokens, or callback URLs in rendered retry links.

9. **Exact redirect URI must be config-driven and tested.**

The client correctly uses the configured callback URL for authorize and exchange. The controller must not derive callback URLs from the request host, proxy headers, or current URL. Add a boot/test assertion that `Schwab.callback_url` exactly matches the registered HTTPS URL.

10. **`fake_authorize` must be impossible in production.**

Do not merely hide the link. The route/action should 404 unless the adapter is fake and Rails is not production. Also fail boot if production runs with `SCHWAB_ADAPTER=fake`.

**Phase 2 Missing Piece**

Order submission will need the same token lifecycle, but stricter. Before submitting, Phase 2 must:
- Require active current token.
- Refresh proactively if access token is near expiry.
- Block approval/submission if re-auth is required.
- Prevent stale in-flight jobs using an old token from pausing or mutating submission state after re-auth.

**Tests I Would Require Before Step 4 Is Accepted**

- Two refresh jobs race; only one HTTP refresh happens.
- Old token refresh fails after new `issue!`; sync remains unpaused.
- Callback hit twice; first succeeds, second does not audit failure.
- Callback with missing/mismatched state fails and consumes nothing.
- Code ending in `@` is exchanged without extra decoding.
- Refresh endpoint 400 pauses only if token row is still active.
- Refresh endpoint 500/timeout records transient failure but does not demand re-auth.
- Monday after successful Sunday re-auth does not nag.
- Monday after missed Sunday ritual does nag.
- Production cannot reach `fake_authorize`.

Step 4 should not be written until the token “currentness” model and escalation clock math are fixed. Those are design-level bugs, not implementation details.
