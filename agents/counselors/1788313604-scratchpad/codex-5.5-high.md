**Findings**

1. [config/database.yml](/Users/jathayde/Development/Personal/desk.athayde/config/database.yml:76) is a first-deploy blocker. The `production:` key is commented out, so the file only defines `default`, `development`, and `test`; I verified that with Ruby YAML parsing. Fix this before any `git push dokku main`, or `db:prepare`/boot may not have a production DB config despite `DATABASE_URL`.

2. The repo currently has no `Procfile`, `app.json`, or `bin/dokku-setup`. With the current [Dockerfile](/Users/jathayde/Development/Personal/desk.athayde/Dockerfile:68), Dokku can start the Dockerfile `CMD`, but only the default `web` process will run. No worker means no Solid Queue recurring tasks, no 07:03 brief, no Sunday email, no token refresh. Dokku’s docs confirm only `web` auto-scales on initial deploy and `worker=1` must be set via `ps:scale` or `app.json` formation.

3. §9 is slightly confused about `app.json`: Dokku’s release phase is a `Procfile` `release:` process, not an `app.json` release phase. `app.json` is useful for formation and healthchecks, but `release: bin/rails db:prepare` belongs in `Procfile`. Dokku’s deployment docs explicitly describe `Procfile` release commands as the release mechanism.

4. `RAILS_MASTER_KEY` is necessary but not identical to `SECRET_KEY_BASE`. The production encrypted credentials file is included in the Docker build, but first boot still depends on the dokku `RAILS_MASTER_KEY` being the production credentials key and that credentials file containing `secret_key_base`, Schwab, MCP, Anthropic, Resend, and AR encryption keys. Missing/wrong credentials will fail early because [production.rb](/Users/jathayde/Development/Personal/desk.athayde/config/environments/production.rb:65) fetches `resend.api_key` at boot.

5. Mail delivery is operationally critical but not hardened. Login, token nags, briefs, and Sunday re-auth all depend on Resend SMTP, yet `raise_delivery_errors` is not explicitly enabled in [production.rb](/Users/jathayde/Development/Personal/desk.athayde/config/environments/production.rb:58). For this app, silent mail failure is a production outage. Set it true and verify Resend DNS before first deploy.

6. `config.hosts = ["desk.athayde.com"]` in [production.rb](/Users/jathayde/Development/Personal/desk.athayde/config/environments/production.rb:83) is correct for Schwab’s registered callback, but it means direct dokku hostnames, IP access, or alternate domains will 403 except `/up`. Verify dokku nginx forwards the original `Host` and `X-Forwarded-Proto`; otherwise `force_ssl`/`assume_ssl` can create redirect or secure-cookie problems.

7. The memory repo plan is incomplete for a private repo. [Memory::Repo](/Users/jathayde/Development/Personal/desk.athayde/app/models/memory/repo.rb:60) correctly uses `GIT_TERMINAL_PROMPT=0` and `safe.directory`, but the deploy doc must settle credentials: either mount an SSH key/known_hosts readable by uid 1000, configure HTTPS credentials non-interactively, or make host cron the sole pull owner. If the app pulls, the mounted checkout and `.git` must be writable by uid 1000.

8. An empty memory mount is not degraded enough. If `MEMORY_REPO_PATH` exists but is empty, `Memory::Repo#present?` returns true, the brief will not report “memory repo missing,” and the pull job will record repeated “not a git checkout” failures. Treat “directory with no known files” as degraded, and decide whether the app should fail pull or merely report host-cron state.

9. Current [db/seeds.rb](/Users/jathayde/Development/Personal/desk.athayde/db/seeds.rb:1) only creates users. That is not enough for the requested dev seed: dashboard, journal, system page, fake brief, accounts, token, positions, orders, activities, market days, trades, setups, snapshots all need seeded state. Also production seeding must be guarded so fake broker data/tokens never seed in production. You still need a production-safe way to create allowlisted users, because `db:prepare` does not run seeds.

10. The 07:03 brief can race the 07:00 sync assumption. [Agent::BriefJob](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/agent/brief_job.rb:36) waits only for currently live `SyncRun`s. If the 07:00 tick is delayed by worker backlog and has not created runs yet, the brief sees no live sync and proceeds on stale data. Morning brief should require last successful syncs after the 07:00 boundary or explicitly enqueue/run the due sync gate before generating.

11. Deploy restarts leave stale sync rows visible. `AgentRun.sweep_stale!` exists, but stale `SyncRun.running` rows are only ignored by `live`; they are not marked failed after a killed worker. The System page can show a stale “running” latest feed, and failure digest won’t count it. Add a sync-run sweep or make status views treat stale running as left-running failure.

12. Sunday phone re-auth is basically sound but fragile across iOS browser contexts. The flow stores Schwab OAuth state in the Rails session in [SchwabController](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/schwab_controller.rb:10), and magic-link login preserves return-to. If Mail opens the magic link in one browser context and Schwab callback returns to another, the callback lands as “Nothing pending.” Test on real iOS Safari before relying on it; server-side OAuth state would be more robust.

**Settle Before First Deploy**

Fix production DB config, add real `Procfile` with `web`, `worker`, and `release`, decide `app.json` formation versus manual `ps:scale`, verify `/up` healthcheck and dokku port mapping, confirm production credentials/secret base, enable mail failure visibility, document/apply memory mount credentials, and create the daily offsite Postgres backup cron required by PRD §5.9.

**Can Wait**

Polishing dev seeds, richer fake brief content, host-cron versus app-pull refinements if the first deploy can run degraded without memory, and iOS robustness beyond a documented “open in Safari” path can wait briefly, but the phone flow still needs a real-device smoke test before the first Sunday ritual.

Sources checked: local repo files above, plus Dokku docs on [process management](https://dokku.com/docs/processes/process-management/), [deployment tasks/release](https://dokku.com/docs/advanced-usage/deployment-tasks/), [Dockerfile deploys](https://dokku.com/docs/deployment/builders/dockerfiles/), [app.json](https://dokku.com/docs/appendices/file-formats/app-json/), and [docker/storage options](https://dokku.com/docs/advanced-usage/docker-options/).
