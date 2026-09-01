## Verdict

Solid adaptation of the 8.1 generator; the concern, `Session`, `Current`, rate limit, and controller shape are idiomatic. Two findings need fixing before commit: the magic link is consumed by a side-effecting GET, and the credentials layout does not match decision 0.1. Everything else is medium or below.

## High

**1. Magic-link GET has side effects.** `app/controllers/sessions_controller.rb:13` logs in, bumps `last_login_at`, and sets the cookie on a plain GET. Consequences:
- Mail scanners and link previewers (Outlook Safe Links, Apple Mail Link Previews, corporate proxies) fetch the URL first, which burns the single-use token, so the real click gets "invalid or expired". That is the failure mode the request specifically asked about, and it is real for this design.
- The token sits in the URL path. Rails' `Started GET` line uses `filtered_path`, which filters the query string only, so the raw token lands in production STDOUT and the dokku nginx access log. `:token` in `filter_parameter_logging.rb` does nothing for path segments.
- It is a login CSRF vector, though moot with a two-person allowlist.

Fix: make the GET render a confirmation page with no side effects, and consume the token from a POST body. Cleanest shape is a tiny `MagicLinksController` with `show` (renders a "Continue to Athayde Desk" button) and `create` (does what `magic` does now), routed as `resource :magic_link, only: %i[show create]`, with the token as `?token=` on the GET so at least Rails' log line filters it. nginx will still log the query string; a 15-minute single-use token bounds that residual. Tests to add: GET does not change `last_login_at` or set a cookie; POST does; move "rejects a used link" to the POST.

**2. Credentials layout is not what §0.1 decided.** Only `config/credentials.yml.enc` and `config/master.key` exist; there is no `config/credentials/production.yml.enc` or dev/test files. Effects:
- `spec/support/vcr.rb:10` decrypts the real Schwab keys on every test run, and running `bin/ci` anywhere else requires the production master key.
- The laptop's master key is the production key.
- I cannot verify the Active Record encryption keys are present since there is no `active_record.encryption` config and the file is opaque. If `db:encryption:init` went into the shared file, dev and prod share a data key.

Fix: `bin/rails credentials:edit --environment production` (and development, test), move `resend` and `schwab` there, put fixed dummy AR encryption keys in dev/test, and set `RAILS_MASTER_KEY` on dokku from the production key.

## Medium

**3. Sessions never expire.** `app/controllers/concerns/authentication.rb:44` uses `permanent` (20 years) and `find_session_by_cookie` checks existence only. Generator default, but this app will hold Schwab tokens behind that cookie. Give sessions an absolute lifetime (30 days is reasonable): `expires: 30.days` on the cookie, and scope the lookup to `Session.where(created_at: 30.days.ago..)`. Add a spec with `travel`.

**4. Missing Resend key fails silently.** `config/environments/production.rb:70` passes nil to SMTP if the key is absent. The failure surfaces inside `MailDeliveryJob` on the worker, with no retry and no digest until step 9, and login is dead. Fail at boot with `Rails.application.credentials.resend!.fetch(:api_key)`.

**5. VCR scrubbing gaps** in `spec/support/vcr.rb`:
- Request bodies are untouched. The refresh grant sends `refresh_token=` and the code exchange sends `code=` form-encoded; both get written verbatim.
- Plaintext `accountNumber` is not scrubbed. It appears in `/accounts/accountNumbers`, in `securitiesAccount.accountNumber` on every account payload, and unquoted as an integer in orders. The plan promises plaintext numbers are never stored; cassettes in git would violate that.
- `id_token` in the token response is not covered.
- The hash regex is uppercase-only; make it case-insensitive.
- Design tension to settle now: `match_requests_on` includes `body`, so once request bodies are scrubbed the token factory must use the literal placeholder or refresh cassettes will never match.

**6. Rate limiting is untested and cannot be tested.** `config/environments/test.rb:23` uses `null_store`, so `rate_limit` is a no-op in the suite. Note that `rate_limit`'s `store:` default is captured at class-load time, so stubbing `Rails.cache` in one example will not work. Switch test to `:memory_store` with `Rails.cache.clear` in a global `before`, then add an 11-request spec asserting the alert.

**7. The return-to spec is vacuous.** `spec/requests/sessions_spec.rb:35` captures `root_url` and asserts `root_url`, which is also the fallback. Use `get root_path(view: "risk")` and expect `root_url(view: "risk")`.

## Low

- `app/models/user.rb:22`: `record_login!` is `touch :last_login_at`.
- `app/models/user.rb:14`: `find_by_magic_link` renames a one-liner; call `find_by_token_for` directly.
- `sessions_controller.rb:9`: `params[:email_address]` as a hash raises inside the `normalizes` lambda. `params.expect(:email_address)` turns that into a 400.
- Mail templates render `MAGIC_LINK_TTL.inspect`. `Duration#inspect` is not a presentation API; use `distance_of_time_in_words`.
- `spec/spec_helper.rb`: enable random ordering and `disable_monkey_patching!` now, while the suite is small.
- Missing tests: email normalization on `POST /session` (post `" John@Athayde.com "` and expect the mail enqueued, since this is the allowlist gate); the HTML mail part contains the link (only `text_part` is checked).
- Untracked `athayde.html`, `.DS_Store`, and `docs/.DS_Store` will get swept into the commit. Add `.DS_Store` to your global gitignore first.
- `config.hosts` may reject dokku's zero-downtime check on `/up` depending on the Host header it sends. The exclusion at `production.rb:88` is ready if it does.
- Development logs the full mail body, and production at `RAILS_LOG_LEVEL=debug` would too. Acceptable, but know it.

## Verified, no action

- `config/ci.rb` is correct: `step` does not abort, `success?` is public, `run` sets `ENV["CI"]` so eager loading is exercised, and `abort` fires on any failure.
- Cookie `secure` flag comes from `force_ssl` in production. `same_site: :lax` is right for a link clicked from mail.
- `normalizes` applies to `find_by`, so the lookup at `sessions_controller.rb:9` is case- and whitespace-safe.
- Enumeration by timing is not worth defending: the two addresses are in `db/seeds.rb` in git, and the known-address branch costs one Solid Queue insert.
- Token brute force is infeasible (HMAC via MessageVerifier), so no rate limit on the consume route is needed.
- Nil `last_login_at` before first login is handled correctly by `generates_token_for`; all pre-first-login links share one payload and all die at first login, which matches intent.
