# Review Request

## Question
Before build step 10 of Phase 1 (development seeds through the fake Schwab client, `Procfile`, `app.json`, `bin/dokku-setup`, and the first production deploy of desk.athayde to a dokku VPS), review the deploy design in @docs/phase-1-plan.md §9 and §10 against PRD §5.9 and §5.11 in @docs/artifacts/investment-copilot-prd.md and against what the app as built actually needs. What will break on the first `git push dokku main`, the first boot, the first 07:03 brief on the VPS, and the first Sunday re-auth from a phone?

## Context
- The app: Rails 8.1, Postgres 17, one database holding Solid Queue/Cache/Cable (migration `InstallSolidTables`), `structure.sql`, Puma web plus one `bin/jobs` worker, Resend over SMTP, Rails credentials with `config/credentials/production.yml.enc` (`RAILS_MASTER_KEY` already set on dokku, Schwab/MCP/Anthropic/Resend keys inside), ENV only for `SCHWAB_CALLBACK_URL` and `MEMORY_REPO_PATH`; `config.hosts = ["desk.athayde.com"]`; `SCHWAB_ADAPTER` and `ANTHROPIC_ADAPTER` default to http in production and fake elsewhere and refuse fake in production.
- Files that exist today: @Dockerfile @config/deploy.yml (if present) @config/puma.rb @config/environments/production.rb @config/recurring.yml @config/queue.yml @config/cache.yml @config/database.yml @bin/jobs @bin/docker-entrypoint @config/initializers/schwab.rb @config/initializers/agent.rb @app/jobs/memory/pull_repo_job.rb @app/models/memory/repo.rb @db/seeds.rb @config/ci.rb
- The Schwab app is approved; the callback URL registered at Schwab is https://desk.athayde.com/schwab/callback. The dokku app already exists on the VPS with letsencrypt and a postgres service (the user did the initial dokku setup and set RAILS_MASTER_KEY); Solid Queue recurring tasks run inside the worker process.
- The memory repo is a private git repo John writes; the plan says a host-side clone mounted into the container owned by uid 1000, with the container's `git pull --ff-only` (git is in the runtime image) or a host cron as the alternative.

## Instructions
You are providing an independent review. Be critical and thorough.
- Deploy mechanics: what dokku needs for a Rails 8 Dockerfile app (ports, `RAILS_ENV`, `SECRET_KEY_BASE` versus the master key, `DATABASE_URL` from the postgres plugin, the release phase in `app.json` running `db:prepare` against a database whose schema is `structure.sql` and includes Solid Queue tables, `ps:scale web=1 worker=1`, the worker's Procfile line, health check at `/up`, nginx `client_max_body_size`, zero-downtime checks), and what breaks with `config.hosts`, `assume_ssl`/`force_ssl`, and Rails host authorization behind dokku's nginx
- The memory repo: storage mount permissions for uid 1000, git safe.directory, ssh or https credentials for a private remote from inside the container, whether the pull job or a host cron is the right owner, and what the seeds and the first brief do when the mount is empty
- Seeds: what a development seed through the fake Schwab client should create so the dashboard, journal, system page, and a fake brief all render (accounts, token, positions, orders, activities, market days, trades, setups, snapshots, users for magic-link login), and what must never be seeded in production (`db/seeds.rb` guard)
- The scheduler: one worker process running recurring tasks plus queues `critical` and `default`, what happens on deploy restarts mid-run (agent runs and sync runs left running), time zone on the VPS, and the 07:03 brief needing the 07:00 tick's syncs
- Backups: the daily offsite dump the PRD asks for, and what `bin/dokku-setup` should document versus do
- The Sunday ritual from a phone: magic link, return-to, Schwab's login page, callback, and the connected page on iOS Safari
- Anything in §9/§10 that contradicts the PRD or the app as built; anything missing from the phase-level review pass. Say what must be settled before the first deploy versus what can wait.
