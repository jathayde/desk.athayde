**Verdict**

Step 4 is improved, but I would not accept it yet. There are two production-breaking bugs and two config issues that can make the lifecycle fail despite the tests passing.

**Findings**

1. **Critical: real OAuth cannot start when no usable token exists.**  
   [app/models/schwab.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab.rb:9) makes `Schwab.client` raise `Schwab::NoUsableToken` unless there is a usable current token. But [authorize](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/schwab_controller.rb:10) and [code exchange](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab_token/reauth.rb:13) both call `Schwab.client` without a token. First auth, expired-token reauth, and revoked-token reauth all fail in production. The fake adapter hides this completely. Split OAuth/token client construction from bearer-token API construction, or allow unauthenticated OAuth methods explicitly.

2. **Critical: stale refresh can still pause sync after a newer re-auth.**  
   [record_failure](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab_token.rb:67) reloads and writes `last_refresh_error`, then checks `current?`, then later writes `revoked_at` and `sync_paused_reason`. A new token can be issued between the `current?` check at line 70 and the pause write at line 72. That recreates the old failure: fresh current token, global sync paused. The current-token check and pause write need to be one atomic conditional operation, preferably under a transaction that locks the singleton settings row and rechecks “no newer token exists” immediately before pausing.

3. **High: the “critical” queue is not actually prioritized.**  
   [config/queue.yml](/Users/jathayde/Development/Personal/desk.athayde/config/queue.yml:6) uses `queues: [ "critical", "*" ]`. Solid Queue documents that a wildcard mixed with explicit queues behaves like `queues: *`, and that priority only wins within the same queue. Also [recurring.yml](/Users/jathayde/Development/Personal/desk.athayde/config/recurring.yml:6) sets `priority: 0`, which is the default and therefore not higher. Use a dedicated critical worker or enumerate queues without `*`, and give non-critical jobs a lower priority number strategy.

4. **High: the health recurring schedule is too risky as written.**  
   [config/recurring.yml](/Users/jathayde/Development/Personal/desk.athayde/config/recurring.yml:10) says `schedule: at 8am and 8pm America/New_York`. Solid Queue recurring schedules are parsed by Fugit; the documented natural recurring form is `every day at ... on America/New_York`, or cron with the timezone suffix. Ship this as unambiguous cron: `0 8,20 * * * America/New_York`. Add a spec or `bin/jobs check` gate for both recurring entries.

5. **Medium: token endpoint error text is not safely scrubbed before persistence/UI.**  
   [Schwab::Scrub](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/scrub.rb:5) only redacts account/user fields. Token endpoint error messages flow through [Schwab::Error](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/error.rb:15), into [last_refresh_error/audit](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab_token.rb:69), and into the failure page via [failed(e.message)](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/schwab_controller.rb:22). Redact `access_token`, `refresh_token`, `id_token`, `client_secret`, and do not render raw Schwab error bodies to users.

**What Holds**

The Monday/Tuesday rule is now the right shape: Sunday 18:30 re-auth stays quiet Monday 08:00; Wednesday re-auth nags next Monday; Sunday 17:00 nags because it was before the 18:00 ritual; DST is handled by constructing Sunday 18:00 in `America/New_York`.

Callback idempotency mostly holds: state is consumed before exchange, double hits become “nothing pending,” forged state writes no token, cancellation avoids the token endpoint, and failure paths do not issue a new token. Missing `refresh_token` on refresh is handled correctly by keeping the old one.

**Missing Specs**

Add real-adapter request/model specs for OAuth with no current token, a true race around `record_failure`, parser checks for `config/recurring.yml`, DST/Sunday-17 health cases, and log/error scrubbing. The current refresh race spec is sequential and does not prove the stale-row pause race is closed.

Sources checked for Solid Queue/Fugit syntax: Rails Solid Queue README and Fugit README.
