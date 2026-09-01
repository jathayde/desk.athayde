**Findings**

**High: Magic-link `GET` both authenticates and consumes the token.**  
[config/routes.rb](/Users/jathayde/Development/Personal/desk.athayde/config/routes.rb:5), [app/controllers/sessions_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/sessions_controller.rb:13)  
This is the biggest auth flaw. Mail scanners, link previewers, safe-browsing systems, and `HEAD`/`GET` prefetches can trigger `magic`, update `last_login_at`, create a session for the scanner response, and burn the user’s link before the user clicks. For this app, make the emailed URL a non-mutating landing page. Require an explicit same-site `POST` with CSRF to consume the token and create the session.

**High: “Single use” is not truly single-use.**  
[app/models/user.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/user.rb:10), [app/controllers/sessions_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/sessions_controller.rb:14)  
`last_login_at&.to_i` gives only second precision, so links generated/used across rapid logins in the same second can remain valid. Also, two concurrent requests can both pass `find_by_magic_link` before either updates `last_login_at`, creating two sessions. Use a dedicated `magic_link_nonce`/version column and rotate it atomically under row lock, or store hashed one-time login tokens and delete/consume them transactionally.

**High: Sessions are effectively permanent.**  
[app/controllers/concerns/authentication.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/concerns/authentication.rb:44), [app/models/session.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/session.rb:1)  
`cookies.signed.permanent[:session_id]` plus a `sessions` table with no expiry means a stolen session cookie is useful indefinitely unless manually destroyed. That is too loose for an app holding Schwab OAuth tokens. Add absolute and idle expiry server-side, sweep old sessions, and set a non-permanent cookie expiry. Consider destroying prior sessions on magic-link login for this single-operator app.

**High: Magic tokens are embedded in the URL path and will leak into logs.**  
[config/routes.rb](/Users/jathayde/Development/Personal/desk.athayde/config/routes.rb:5), [config/initializers/filter_parameter_logging.rb](/Users/jathayde/Development/Personal/desk.athayde/config/initializers/filter_parameter_logging.rb:6)  
`:token` is filtered as a parameter, but the bearer token is in the path: `/session/magic/:token`. Rails logs, reverse-proxy logs, browser history, mail security systems, and observability tools commonly retain paths. Move the token out of the path at minimum, and explicitly configure app/proxy logging to avoid recording magic-link URLs. The better fix is a short-lived, non-mutating landing URL plus POST consumption.

**Medium: No session fixation defense on login.**  
[app/controllers/concerns/authentication.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/concerns/authentication.rb:41)  
`start_new_session_for` creates the app session but does not call `reset_session`. Rails’ own security guide recommends issuing a new session identifier after successful login. Preserve `return_to_after_authenticating`, call `reset_session`, then set the new session cookie.

**Medium: Credential layout does not match the plan.**  
[config/environments/production.rb](/Users/jathayde/Development/Personal/desk.athayde/config/environments/production.rb:70)  
The plan says production-only credentials at `config/credentials/production.yml.enc`, but the repo only has `config/credentials.yml.enc`, and that file is modified. `config/master.key` is ignored and not tracked, which is good, but the intended environment-specific credential separation is not implemented. Before Schwab tokens exist, create the production credential file and keep dev/test credentials separate.

**Medium: VCR scrubbing is incomplete for OAuth and account data.**  
[spec/support/vcr.rb](/Users/jathayde/Development/Personal/desk.athayde/spec/support/vcr.rb:10)  
The scrubber removes `Authorization` and response `access_token`/`refresh_token`, but it does not scrub form-encoded request bodies containing `client_secret`, `client_id`, authorization `code`, `refresh_token`, or `redirect_uri`. It only redacts uppercase 64-char account hashes in `/accounts/...`, and only `"hashValue"` response fields. Expand this before recording any real Schwab cassette.

**Low: Email lookup does not normalize input.**  
[app/controllers/sessions_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/sessions_controller.rb:9)  
The model normalizes stored email, but `params[:email_address]` is queried raw. `" John@Athayde.com "` will not receive a link despite matching the seeded user after normalization. Normalize before lookup and add a request spec.

**Missing Tests**

Add tests for scanner-safe flow: `GET`/`HEAD` must not log in, mutate `last_login_at`, or create a `Session`; only CSRF-protected `POST` may consume.

Add tests for concurrent or repeated token use, including same-second login.

Add cookie/session tests for `httponly`, `secure`, `same_site`, expiry, session revocation, and server-side expiration.

Add VCR scrubber tests with token endpoint request/response examples and account hash variants.

I did not run the suite: this environment cannot satisfy the lockfile’s Bundler `4.0.4` requirement with the available `/usr/bin/bundle`.

Reference used for Rails security expectations: [Rails Security Guide](https://guides.rubyonrails.org/security.html).
