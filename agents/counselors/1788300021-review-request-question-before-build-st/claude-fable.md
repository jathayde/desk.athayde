I have what I need. Here is the review.

# Second opinion: step 4 OAuth and token lifecycle

Ordered by severity. The first three will each cause a real outage or a false pause in production; fix them in the design before writing code.

## 1. Critical: the Mon/Tue escalation rule fires every week, including after a successful Sunday re-auth

Walk the numbers. Re-auth Sunday 18:30 → `refresh_expires_at` = next Sunday 18:30. Monday 08:00 health run: coming Sunday 18:00 + 12h = Monday 06:00. Sunday 18:30 < Monday 06:00 → nag. Same on Tuesday. The rule as written is a false positive for every properly re-authed token, because a 7-day token issued on Sunday evening always expires within about an hour of the next Sunday email, and any buffer larger than that gap trips it.

The PRD's actual condition is "the re-auth hasn't happened" after the Sunday email. Encode that literally:

```
escalate = monday_or_tuesday && SchwabToken.current.issued_at < most_recent_sunday_18:00
```

No buffer, no comparison against the coming Sunday. Add a spec that travels to Monday 08:00 after a Sunday 18:30 re-auth and asserts no nag.

## 2. Critical: a 4xx on a superseded or revoked token pauses sync with a valid token in hand

Two paths produce this:

- **Refresh races the callback.** Row A is mid-refresh (lock held, HTTP in flight) while the callback inserts row B and clears the pause. If Schwab invalidates A's refresh token when B is issued (unverified), A's refresh comes back 4xx → `ReauthRequired` → the design writes the pause. Nothing ever clears it, because the re-auth already happened. Sync is dead with a fresh token in the table.
- **Stale token object in a running job.** Jobs hold the `SchwabToken` row they loaded at start. After re-auth mid-run, a 401 triggers `refresh!` on the old row, which hits the same path.

Also, a token that Schwab revokes early (secret rotation, portal action, a 7-day window that is really 6.9) gets a 4xx while `refresh_expires_at` is still in the future. The refresh job's no-op check is "refresh expired", so it keeps calling Schwab every 25 minutes and writing `token_refresh_failed` forty times a day, and `TokenHealthJob` stays silent because the 24h window has not opened. That is the "silently kills all automation" risk in a new costume.

Fix all three with one rule: **pause state is derived from the current token, never written by a failure.**

- Add `revoked_at` to `schwab_tokens`. `refresh!` sets it on `ReauthRequired` for the current row only. `usable?` = present, not refresh-expired, not revoked.
- `refresh!` on a non-current row does nothing (reload inside the lock, compare id to `SchwabToken.current.id`, return). Better: have the client resolve the token per request through a class-level accessor so there is no stale object at all.
- `TokenGated`, the tick job, and the banner all read `usable?`. `sync_paused_reason` becomes a label written on the unusable transition (audit once, under the singleton row lock) and cleared on re-auth. Nothing gates on it.
- `TokenHealthJob` nags immediately when the current token is revoked or absent, not only inside the 24h window.

## 3. Critical: the row lock does not prevent a double refresh, and writes inside it roll back on error

`with_lock` serializes two refreshers, but the second one acquires the lock after the first commits and refreshes again. Reload inside the lock and skip if `last_refreshed_at` is within the last minute. The client's 401 retry then works correctly for the second thread too, because it re-reads the new access token.

Separately, if `refresh!` raises inside the `with_lock` block, the transaction rolls back and `last_refresh_error` is never persisted. Rescue inside the block and save, or write the error after the block.

Also note the lock is held across an HTTP call with retries: up to roughly 80 seconds on a 5xx streak (1+4+16 s backoff plus timeouts). With one worker process and three threads this is tolerable, but the refresh grant should skip the backoff budget when called from the 401 path, or the sync job that triggered it will sit on its own thread for over a minute.

## 4. High: 5xx and transport failures on the token endpoint must never pause

The design only mentions `ReauthRequired`. Make the job explicit: `ServerError` and `TransportError` record `last_refresh_error`, do not touch `revoked_at`, and let the next tick or 401 path retry. If Schwab's token endpoint is down for over 30 minutes the sync jobs will fail with `AuthError`; that is fine and lands in the failure digest. `AuthError` on a data call after a successful refresh must also not pause.

Handle a refresh response missing `refresh_token`: `refresh_expires_at` and `refresh_token` are NOT NULL, so a nil write raises and you lose the new access token. Use `response["refresh_token"].presence || current value`.

## 5. High: callback hardening

- **Redirect after exchange.** Render nothing on the callback GET. Exchange, then redirect to a clean success page. Otherwise a browser refresh re-submits a single-use code, fails with `invalid_grant`, and audits `re_auth_failed` for a non-event. Same fix removes the code from any Referer.
- **Failure never touches the table.** A failed exchange must not write to `schwab_tokens`, `revoked_at`, or the pause. The prior token is still valid.
- **Handle `params[:error]`.** Schwab sends `error` when the user cancels. Do not call `exchange_code(nil)`.
- **Distinguish two failure kinds.** No pending state in session (duplicate hit, expired flow) renders "nothing pending, start again" with no audit. Pending state that mismatches is CSRF and does get audited.
- **State is single-use and expires.** Delete it on first read; reject if older than 10 minutes.
- **Retry link goes to `authorize`**, never back to the callback.
- **Add `code`, `state`, and `session` to `filter_parameters`.** Rails logs the filtered path on the "Started GET" line, and `:token` does not match `code`. The nginx access log will still have it; single-use and short-lived, acceptable.
- **Enqueue `Sync::CatchUpJob` after commit**, not inside the transaction that inserts the row, so the job cannot load the old `current`.

## 6. High: bind the token to the known accounts

State is the CSRF defense, and `docs/verify-on-approval.md` item 3 says Schwab echoing it is unverified. If it turns out Schwab does not echo state, a forged callback could bind an attacker's Schwab login to the app. In Phase 2 that means the submission path trades in the wrong account. Defense in depth costs one call: after `issue!`, fetch `/accounts/accountNumbers` and compare hashes against the `accounts` table. On first auth, accept. On any later auth, a hash set that does not overlap the known set is a failure: do not make the row current, audit, show an error. This also catches John re-authing with the wrong Schwab login.

## 7. Medium: nag fatigue in the healthy path

With re-auth on Sunday evening the token enters the 24h window Saturday evening. The user then gets Saturday 20:00, Sunday 08:00, and the Sunday 18:00 ritual email every single week. Three emails a week for a healthy system trains the user to ignore the one that matters. Send the 24h warning once per token row (dedupe on token id in `token_nag_sent` data), and escalate to twice-daily only when expired, revoked, or absent, or after the Sunday email went unanswered.

## 8. Medium: clock and scheduling notes

- Solid Queue 1.7 interprets schedules without a zone in `config.time_zone`, which is Eastern here, so 08:00, 20:00, and Sunday 18:00 are correct across DST. Put `America/New_York` in the cron strings anyway so a future change to `config.solid_queue.time_zone` cannot silently shift them.
- "every 25 minutes" parses to `*/25`, giving gaps of 25, 25, and 10 minutes. Never more than 25, so the 30-minute access token holds. Missed runs are not backfilled, so a worker restart at a slot boundary leaves the access token to expire; the 401 refresh path is the real safety net and needs a WebMock spec of its own, since `FakeClient` never exercises it.
- Give the refresh task a higher priority in `recurring.yml`. Transactions sync loops eleven types per account and can hold all three threads for minutes.
- Use `expires_in` from the response with a 60-second margin for `access_expires_at`. Add `ensure_fresh!(margin:)` on the model so a caller can refresh proactively instead of burning a 401.
- `SchwabToken.current` should order by `issued_at desc, id desc`, and `Schwab.client` should raise a typed error when no usable token exists instead of letting `nil.access_token` blow up in a web request or MCP tool.
- Refresh-token rotation is unverified (item 5). The client marks the refresh grant idempotent and retries it after a read timeout. If Schwab does rotate one-time refresh tokens, that retry returns `invalid_grant` and looks like revocation. Note it in verify-on-approval as a specific test: refresh, kill the connection mid-response, refresh again.

## 9. Medium: the fake adapter can reach production

The initializer reads `SCHWAB_ADAPTER` in every environment. One stray dokku config var puts fake positions on a real dashboard and exposes `fake_authorize`. Ignore the env var in production, or raise at boot if the adapter is not `:http`. Guard the fake controller action itself too, not just the route definition.

For Playwright, let `fake_authorize?fail=1` redirect with a bad code. It is simpler than reaching the singleton's queue from another process through the scenarios route.

## 10. Phase 2 gaps to settle now

- The submission POST does not go through the 401 refresh path, which lives only in `get`. Decide now: a 401 on POST means "not submitted" and is safe to retry once after refresh. Document that in the client and call `ensure_fresh!` before any non-idempotent request so it almost never happens.
- The approved → submitted transition must check `usable?` under its row lock and fail with a clear reason, not fall into `submission_unknown`.
- Confirm the individual Trader API product's single `api` scope covers order placement. Add to verify-on-approval.
- Puma will refresh tokens too once MCP tools call Schwab from the web process. The row lock covers cross-process; the "reload and skip if recently refreshed" check is what makes it correct.

## Requirements coverage

Against §5.1 and §5.10 the design covers refresh cadence, 7-day expiry from issuance, the 24h notice, pause, catch-up, and the Sunday ritual. Missing or implicit: `sync_resumed` audit on the callback when a pause was active, a nag for the no-token state before first auth, and the token-age metric (`issued_at` exposed for Flow 8). The Resend dependency is the remaining single point of failure: every alert is email. Put the token status line at the top of the morning brief so a dead nag path is still visible daily, and let a failed nag delivery raise so it shows in Solid Queue failed executions on the system page.
