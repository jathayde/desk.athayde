# Review Request

## Question
Phase-level review of the Investment Copilot Phase 1 build (read-only) before its first production deploy. All ten build steps are committed on `main` in /Users/jathayde/Development/Personal/desk.athayde (`git log --oneline` shows them). Judge the whole against @docs/artifacts/investment-copilot-prd.md (v9, Phase 1 scope in §6) and @docs/phase-1-plan.md, which records every decision and every review-driven revision. What in this codebase would make the first week on a real account go wrong, and what did the per-step reviews miss because they only saw one step at a time?

## Context
- Rails 8.1 / Ruby 3.4, Postgres, Solid Queue, Hotwire, no build step; 360 specs and 13 Playwright scenarios green under `bin/ci`.
- Layers: Schwab adapter (`app/models/schwab/`), token lifecycle (`app/models/schwab_token.rb`, `app/controllers/schwab_controller.rb`), sync (`app/jobs/sync/`, `app/models/sync_run.rb`, `app/models/market_day.rb`), journal (`app/models/trade.rb`, `app/models/journal/`, `app/models/snapshot.rb`), screens (`app/models/dashboard.rb`, `app/models/system_status.rb`, controllers and views), MCP (`app/controllers/mcp_controller.rb`, `app/models/agent/`), scheduled runtime (`app/models/agent/run.rb`, `app/jobs/agent/`, `app/mailers/brief_mailer.rb`, `app/models/brief.rb`), deploy (`Dockerfile`, `Procfile`, `app.json`, `bin/dokku-setup`, `db/seeds.rb`).
- Live facts: the Schwab app is approved and a real token has synced the real account (one cash account, three positions); `docs/verify-on-approval.md` lists what remains unverified; `docs/schwab-api-contract.md` is the adapter's contract.
- Constraints that must hold: secrets only in credentials; never log or store plaintext account numbers; tokens encrypted at rest; CUSIP is instrument identity; every "logged" action is an audit_events row; no live Schwab calls in tests; scheduled runs read-only; Phase 1 writes nothing to Schwab.

## Instructions
You are providing an independent review. Be critical and thorough. Read the code, not just the plan.
- Cross-layer contracts: does what sync writes match what the journal, snapshots, Dashboard, tools, and briefs read (statuses, as-of stamps, stale rules, plug legs, ratios, flows)? Where do two layers define the same rule differently?
- The 7-day token ritual end to end: Sunday email, re-auth from a phone, the Monday/Tuesday escalation, expiry mid-week, pause and catch-up, the briefs during a pause.
- Money and identity: any path where an account hash, account number, raw payload, or email reaches a log, a tool result, an email, or a page; any place BigDecimal precision or time zone handling could shift a number.
- Failure surfaces: what a killed worker, a Schwab outage, a Resend outage, an Anthropic outage, an empty memory mount, or a holiday does to each layer, and whether the operator learns of it from the system page, the digest, or nothing.
- Security: the MCP door, the magic-link flow, host authorization, rate limits, the Playwright-only route, Brakeman blind spots.
- Phase 2 readiness: what in the schema or the registry will have to change for proposals, guardrails, and write tools, and what should be changed now while it is cheap.
- Specs: the suite's blind spots (enqueue paths, clock-dependent examples, fixtures that hide real shapes).
Rank by severity; separate "before the first deploy" from "first week" from "later".
