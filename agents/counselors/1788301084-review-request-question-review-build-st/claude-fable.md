I've finished tracing the code and verified the schedule grammar upstream. Here is the review.

# Step 4 review: Schwab OAuth round trip and token lifecycle

## Verdict

The design fixes from the earlier review hold. The Monday/Tuesday predicate, the derived pause state, the reload-inside-lock refresh, callback idempotency, and account binding are all implemented correctly and I could not break them on paper. One bug is production-fatal and invisible to the suite: the client factory refuses to build for OAuth calls when there is no usable token, which is exactly when re-auth happens. Fix that before anything else.

## Findings, by severity

**1. Critical: re-auth cannot run in production once the token is expired, revoked, or absent.**
`Schwab.client` with no token argument resolves `SchwabToken.current` and raises `NoUsableToken` unless it is usable (`app/models/schwab.rb:12`). Both OAuth entry points call it that way: `authorize` at `app/controllers/schwab_controller.rb:10` and the code exchange at `app/models/schwab_token/reauth.rb:13`. Consequences with the http adapter and a dead token: the authorize link 500s because nothing rescues there, and the callback rescues it as a `Schwab::Error` and renders the failure page reading "no usable Schwab token; re-authenticate" with a Try again link that loops forever. The Sunday ritual works only while the old token is still alive, which is the one case where it matters least. The fake adapter returns the singleton regardless, so every request spec passes, and the spec at `spec/models/schwab_token_spec.rb:123` enshrines the behaviour. OAuth grants carry Basic auth, not a bearer, so they need no token at all. Add `Schwab.oauth_client` returning `Client.new(token: nil, wait: false)` and use it for `authorize_url` and `exchange_code`. Keep `NoUsableToken` for data calls. Add a request spec that forces the http adapter, has no token row, stubs the token endpoint with WebMock, and drives the full callback.

**2. High: web requests sleep through the retry budget.**
`verify_accounts!` builds a client with the default `wait: true` (`app/models/schwab_token/reauth.rb:26`), so a 5xx or 429 streak on the account-numbers call holds a Puma thread for up to about 100 seconds inside the callback. `refresh!` has the same problem from the other side: it builds its own client with `wait: true` (`app/models/schwab_token.rb:40`) even when triggered by the 401 path of a `wait: false` web client, and it does so while holding the row lock, so every worker thread that hits the same row blocks behind it. Give `refresh!` a `wait:` keyword, have `Client#authorized` pass its own flag through, and have `Reauth` use `wait: false`.

**3. Medium: the Monday/Tuesday rule is right, but its message lies in one case.**
Re-derived from `app/jobs/schwab/token_health_job.rb:25`: nag on Monday or Tuesday when `issued_at` is before the most recent Sunday 18:00 ET. Sunday 18:30 then Monday 08:00: no nag. Wednesday then next Monday and Tuesday: nag both days, at both runs. Because the lifetime is a fixed 168 hours, this predicate is equivalent to "the token dies before the next Sunday email," which is the condition that actually matters. The Sunday 17:00 edge therefore nags on Monday and Tuesday, which is defensible, but the email says "The Sunday re-auth did not happen" while also saying the token was issued 15 hours ago. Reword it to state the consequence: the token expires before next Sunday's email. DST checks out: `time_zone.local` builds 18:00 correctly on both transition Sundays, and `168.hours` is elapsed time. One consequence worth a comment in the code: the fall-back week has 169 hours, so a Sunday 18:30 re-auth on October 25, 2026 expires at 17:30 on November 1, thirty minutes before the email. Nothing false fires, but sync pauses for an hour on a Sunday. No spec covers the 17:00 edge, the DST week, or the 20:00 runs.

**4. Medium: nag fatigue on the healthy path is only half fixed.**
The 24-hour warning is once per token now, but a token issued every Sunday at 18:30 enters the window on Saturday evening and triggers the 20:00 run every single week. That is 52 emails a year for a healthy system, on top of the Sunday ritual email. Suppress `:expiring` when `refresh_expires_at` is at or after the next Sunday 18:00, since the ritual email already covers that case. The Sunday 17:00 token still warns, consistently with finding 3.

**5. Medium: the schedule strings are unverified and Solid Queue drops invalid ones quietly.**
Fugit's grammar accepts a leading `at` and a bare zone without `in` or `on`, so "at 8am and 8pm America/New_York" should parse to `0 8,20 * * * America/New_York`, and "every 25 minutes" gives `*/25`, with a 10-minute gap at the top of each hour. I verified this against the parser source, not by running it. Solid Queue validates each recurring task and skips invalid ones rather than failing boot, so a typo here silences the health job with no signal. Add one spec that loads `config/recurring.yml` and asserts each schedule parses to a `Fugit::Cron` with the expected hours and zone. Separately, `priority: 0` in `config/recurring.yml:6` is the default and does nothing. Lower numbers win, and the queue order in `queue.yml` is what actually puts refresh ahead of sync. Delete the key or set it to a real value with a comment.

**6. Medium: the superseded-during-HTTP path is correct but untested.**
The dangerous sequence is: row A passes the `current?` check inside the lock, the callback inserts row B during A's HTTP call, and A's refresh comes back `ReauthRequired`. `record_failure` reloads and rechecks `current?` before revoking or pausing (`app/models/schwab_token.rb:70`), so A writes only its error string. Good. The spec at `spec/models/schwab_token_spec.rb:103` tests the early `:stale` return, not this path. It is easy to cover: stub `current?` to return true then false and assert no revocation, no pause, and the error recorded.

**7. Low: a narrow pause-after-clear race remains.**
Between A's `current?` check in `record_failure` and its write of `sync_paused_reason`, B's transaction can commit and clear the pause, leaving a stale label next to a usable token. Nothing gates on the label, so the cost is a wrong banner. Locking the `SystemSettings` row before the `current?` check serializes it against `issue!` and closes the window.

**8. Low: a malformed 200 from the token endpoint bypasses failure recording.**
`fetch("expires_in")` and `fetch("access_token")` raise `KeyError`, which neither rescue in `refresh!` catches. The job fails loudly, which is fine, but `last_refresh_error` stays empty. Wrap as `MappingError`.

**9. Low: log and page leakage.**
Filtering is right: `code`, `state`, and `session` are covered, the request log shows the filtered path, the mailer body carries only prose and the authorize URL, and no exception message embeds a token response. Two small leaks: the "Redirected to" log line in `authorize` is not filtered and prints the full authorize URL including `state` and the app key, and the failure page renders `e.message`, which can include up to 200 characters of a gateway HTML body. Neither is exploitable without the session cookie.

**10. Low: cancellation ordering depends on Schwab echoing `state` on error redirects.**
If Schwab omits `state` on `error=access_denied`, the callback audits it as CSRF. Unverified either way. Add it to verify-on-approval next to item 3.

**11. Low: cleanup.**
The `data->>'reason'` clause in `already_warned?` is dead, since the audit writes `reason` as a column. `CatchUpJob` audits `sync_resumed` on every re-auth even when nothing was paused. The index in the migration is on a table that grows by about one row per week. The `- 0` in `most_recent_sunday_email` is noise.

## Verified and holding

The double hit, browser refresh after redirect, forged state, expired state, user cancel, and unauthenticated hit all behave as designed, and no failure path writes a token row. Two processes on the same 401 refresh once, and the second re-reads the new access token because `lock!` reloads. The debounce cannot suppress a needed refresh after a failure, since `last_refreshed_at` is set only on success. The rescue outside `with_lock` sees only committed state because it reloads first and nothing is written before the raise. `fake_authorize` 404s outside the fake adapter and production refuses to boot with it. The queue order in `queue.yml` is valid Solid Queue syntax.

## Specs to add or strengthen

- Http adapter with no token row through the whole callback, plus `authorize` with no token (finding 1).
- Sunday 17:00 re-auth, the November 1, 2026 fall-back week, and the Monday 20:00 run (finding 3).
- `record_failure` on a row superseded mid-call (finding 6).
- `config/recurring.yml` parse assertions (finding 5).
- In the two-holders spec, assert `second.access_token` equals the rotated value, not just `:recent`.
- A `TokenMailer` spec per reason that asserts the body contains neither token value.
- Callback with neither `code` nor `error` returns 400 without an audit.
- `token_health_job_spec` asserts subjects only. Also assert the audit `reason` and `data.token_id` for at least one run.
