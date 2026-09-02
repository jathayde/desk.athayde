Review is assembled. Writing it up now.

**Short version.** The first `git push dokku main` fails in the image build, the first boot has a port mismatch and a dead database stanza, the first brief runs undegraded against an empty memory mount while the pull job fails every 30 minutes, and the Sunday flow works from a phone as long as it happens in Safari and every account is ticked on Schwab's consent screen.

## What breaks, in order

**First push: the Docker build dies in asset precompile.** `config/environments/production.rb:69` calls `credentials.resend!` at load time. During `assets:precompile` the build has no master key, credentials read as empty, and the bang method raises KeyError. The Rails Dockerfile's `SECRET_KEY_BASE_DUMMY` trick exists precisely so production.rb can load without credentials. Fix with `dig(:resend, :api_key)` there and move the presence check into an initializer that skips when `SECRET_KEY_BASE_DUMMY` is set. Do not "fix" it by declaring `ARG RAILS_MASTER_KEY` and adding a build arg; that bakes the key into a layer that stays on the host.

**First boot: nginx gets a 502.** The Dockerfile keeps `EXPOSE 80` and the thruster CMD, but the planned Procfile runs Puma on `PORT` with a 3000 fallback. Dokku maps whatever `EXPOSE` says, and because the app was created and letsencrypt'd before any image existed, the current map is almost certainly `http:80:5000 https:443:5000`. No combination of those three numbers agrees. Pick one container port and make everything match: my recommendation is to delete `EXPOSE 80` and the thruster CMD, let dokku default to 5000 and set `PORT=5000` itself, and confirm with `dokku ports:report`. That also makes the app.json healthcheck port default correct. Keep the entrypoint as is; with a Puma Procfile line it is a plain exec, and only the release phase touches the schema.

**First boot: the production database stanza does not exist.** `config/database.yml:76` reads `#   production:` and the three lines under it attach to the `test` mapping. Production boots only because Rails falls back to a bare `DATABASE_URL` config when the environment has no stanza, so `max_connections` is ignored and the comment about dokku is attached to the wrong environment. Restore the key. One-line fix, but it means nobody has booted this app as production yet.

**First boot: the worker never starts.** Dokku's initial deploy starts `web=1` only. Without `ps:scale desk web=1 worker=1` or a `formation` block in app.json there is no scheduler, so no ticks, no refresh, no briefs, and the only symptom is a System page saying "never". Put `formation` in app.json and the scale command in the setup script.

**First release: `db:prepare` seeds production.** On a database that exists but has no `schema_migrations` table, `db:prepare` loads structure.sql, migrates, and then runs seeds. Today that creates the two users, which is what you want. After step 10 it runs whatever the development seed does, so the production guard is not a nicety; it is the difference between a clean first release and fake positions in production. Guard on both `Rails.env.development?` and `Schwab.fake?` and keep the users block outside the guard. The existing seeds spec already proves only users appear in test; keep it as the regression.

**First release: Postgres version.** The dokku postgres plugin now defaults to Postgres 18, not 17, and older plugin versions defaulted to 16. structure.sql opens with `SET transaction_timeout`, which Postgres 16 rejects and aborts the load under `ON_ERROR_STOP`. Check `dokku postgres:info` before pushing. If the service is 18, the plan's "postgres:17" line is wrong and local restores of its dumps need matching tooling.

**First 07:03 brief: three things go wrong quietly.**
- **Empty memory mount is not degraded.** `Memory::Repo#present?` is true for any directory, so a mounted but unpopulated path produces a brief with zero memory files and no degraded reason. Meanwhile the pull job records a failed `memory_repo` run every 30 minutes, 48 rows a day into the digest. Make "no known files" a degraded reason and make the job skip or record once when the path is not a checkout.
- **No trading account until the operator acts.** After the first connect, accounts land with no type and `trading_enabled: false`. Until you set the taxable account on `/system` the same evening, the brief says "no trading account is set up yet" and nothing journals or snapshots.
- **Anthropic and Resend are exercised for the first time at 07:03.** A missing key is handled and emailed as a failed brief, but a Resend failure at that moment is silent except for a Solid Queue failed execution. Send one magic link from the VPS before Sunday to prove outbound 465 is open on Greencloud and the sending domain is verified.

**Deploy restarts mid-run.** Dokku's stop timeout is 30 seconds and Solid Queue's shutdown timeout is 5, so an agent run in flight is killed. Its row stays `running`; Solid Queue re-runs the job about 5 minutes later once the dead process is pruned, and `AgentRun.served?` treats the still-running row as served, so the retry does nothing. The 20-minute sweep then marks it failed and the digest reports it at 17:15, but no brief goes out. Either have `served?` ignore `stale_running`, or accept it and document: no deploys 06:55 to 07:20 or 16:25 to 16:50, recovery is `agent:brief[kind]`. Sync runs are fine: `SyncRun.live` gives up after 10 minutes, and two workers overlapping during a deploy are safe because recurring executions and concurrency keys dedupe.

**Sunday from a phone.** The flow holds: the email link to `/schwab/authorize` stores return-to, the magic link page is a GET with a POST button so mail scanners cannot burn it, `reset_session` preserves return-to, both cookies are `SameSite=Lax` so the top-level redirect back from Schwab carries them, and the 30-day session means most Sundays skip the login entirely. Two things to say in the Sunday email:
- **Tick every account on Schwab's consent screen.** The callback rejects a login whose account list does not overlap the known hashes, and a login that drops the IRA silently stops syncing it.
- **Do it in Safari, not the home-screen app.** The layout declares `mobile-web-app-capable`, and a standalone PWA on iOS has its own cookie jar; a magic link tapped in Mail opens in Safari and never signs the PWA in.
The `STATE_TTL` of 10 minutes is tight for a Schwab login with a slow SMS code; 15 is safer and costs nothing.

## Settle before the first push

1. **production.rb credential bang** as above.
2. **database.yml production stanza** restored.
3. **One container port** across Dockerfile, ports map, and app.json healthcheck. Add a startup check:
   ```json
   { "healthchecks": { "web": [ { "type": "startup", "name": "up", "path": "/up", "attempts": 12, "wait": 5, "timeout": 5 } ] },
     "formation": { "web": { "quantity": 1 }, "worker": { "quantity": 1 } } }
   ```
   `/up` is already excluded from host authorization and `assume_ssl` stops the force_ssl redirect, so the check passes on the container IP. Nothing else about `config.hosts` breaks behind dokku's nginx: the Host header passes through, the ACME challenge is served by nginx, and docker bridge addresses are in Rails' default trusted proxies so `remote_ip` and the login rate limit see the real client.
4. **Release phase, one mechanism.** §9 lists both a Procfile `release` line and an app.json release phase. Dokku supports the Procfile form and runs it after predeploy, before any container, through the entrypoint. Use that and keep app.json for healthchecks and formation only.
5. **Seeds guard** as above.
6. **Memory repo ownership decision.** The runtime image has git but no ssh client, no key, no known_hosts, and `GIT_TERMINAL_PROMPT=0`, so an in-container pull of a private remote fails on its first run over SSH and needs a token in the remote URL over HTTPS. That is a secret on disk in a git config, which I would not ship. Decide for the host cron: `storage:ensure-directory --chown heroku` gives 1000:1000, which matches the image's `rails` user; clone as whichever host user owns uid 1000, give that user a read-only deploy key, cron `git pull --ff-only` every 30 minutes, and change the job to record head SHA and mtime instead of pulling. The plan already names this alternative; the code does not implement it.
7. **Credentials audit.** Confirm production.yml.enc holds `secret_key_base`, `active_record_encryption` primary key, deterministic key and salt, schwab, mcp, anthropic, and resend. A missing `secret_key_base` fails boot; missing encryption keys fail at the Sunday `issue!`, which is the worst possible moment. Then `config:unset SCHWAB_APP_KEY SCHWAB_APP_SECRET` per decision 0.1.
8. **Resend proven from the VPS** before the first login. Fallback is already built:
   ```
   dokku run desk bin/rails "login:link[john@athayde.com]"
   ```
9. **First-evening runbook** in `bin/dokku-setup` or a doc: push, watch release, sign in, connect Schwab, configure the taxable account on `/system`, clone the memory repo into the mount, wait for a tick, check the System page feeds, and confirm the worker is running.

## Can wait

- **Backups.** Not blocking the push, but in place within the first week. The plugin does the whole job on the host:
  ```
  dokku postgres:backup-auth desk-db KEY SECRET us-east-1 s3v4 https://ENDPOINT
  dokku postgres:backup-set-encryption desk-db PASSPHRASE
  dokku postgres:backup-schedule desk-db "0 8 * * *" BUCKET
  dokku postgres:backup desk-db BUCKET   # once, then restore it locally
  ```
  08:00 UTC is 04:00 New York, clear of every job window. The bucket keys live in the plugin, not Rails, so the credentials rule is untouched. The thing to protect alongside the dump is `config/credentials/production.key`; without it the dump's encrypted tokens and every secret are unrecoverable.
- **`bin/dokku-setup` scope.** Do the idempotent, secret-free settings: config vars, ports, nginx body size, storage directory and mount, scale, stop timeout. Print the one-time steps that need secrets or root: postgres create, backup-auth, the deploy key. It should be re-runnable and should never `config:set` a secret.
- **nginx body cap.** Dokku's template already uses nginx's 1m default; set it explicitly with `nginx:set desk client-max-body-size 1m` and rebuild the config so the MCP cap does not depend on a default.
- **Worker restart policy.** Default is `on-failure:10`; after ten crashes the scheduler stays down with no nag. `ps:set desk restart-policy unless-stopped`.
- **Image weight.** `BUNDLE_WITHOUT="development"` still installs the shared development-and-test group, so rspec, brakeman, and factory_bot ship to production. Use `development:test`.
- **RAM.** Web plus a Solid Queue supervisor, worker, dispatcher, and scheduler is five Ruby processes before Postgres. Check the Greencloud plan; `SOLID_QUEUE_IN_PUMA` is the escape hatch, at the cost of the separate worker the plan assumes.
- **Time zone** needs nothing: the container is UTC, `config.time_zone` is Eastern, recurring cron strings carry an explicit zone, and there is no `Date.today` or `Time.now` in app code.

**Seeds, concretely.** Drive the real jobs against the fake client rather than the factories, but two things will bite. Development uses Solid Queue, so every `perform_later` the sync jobs fire, including the journal hand-off, sits in the queue until `bin/jobs` runs; wrap the seed in the inline adapter or call the follow-on jobs with `perform_now`. And the shipped fixtures give one buy fill, one dividend, one deposit, and two working stops, so they render a healthy dashboard but no closed trade, no R, no setup stats, and a single balance row. Script extra payloads with `FakeClient#enqueue` instead of editing the fixtures the specs and Playwright depend on: a third symbol bought and sold for a closed trade with a setup, a sell without a buy for the review queue, positions runs under `travel_to` across the last ten trading days so `Snapshots::RebuildJob` has dated balances, one scripted `FakeAnthropic` response through `Agent::MorningBriefJob` so the System page has spend and the journal has a delivered brief in `tmp/mails`, and one scripted failure for a failed sync run. Never seed in production: a token row, accounts, anything with a `raw` column, trades, setups, agent runs, market days, or any change to `system_settings`, especially `shadow_mode`.

**Plan versus PRD.** §5.9 still says the Schwab key and secret live in dokku config vars; decision 0.1 supersedes it and the plan should say so in §9. §5.9's "daily DB dump to offsite storage" has no concrete step in §9; the commands above are it. §5.6's "the VPS pulls the repo on a schedule" reads as the host cron, which is the design I am recommending. §9's "the dump pins Postgres 17 settings, so dokku runs postgres:17" is an assumption about a service that was created without checking; verify it. Nothing in §10's ordering is wrong, but step 10 as written omits the Dockerfile edits, the app.json contents, the worker scale, and the seeds guard, and all four are on the path to the first push.
