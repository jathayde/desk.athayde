# Claude Code Kickoff: Investment Copilot, Phase 1

Paste this as the opening prompt in Claude Code, with `investment-copilot-prd.md` and `investment-copilot-ui-flows.md` in the repo root (or `/docs`). The PRD is the source of truth; where this brief and the PRD disagree, the PRD wins.

---

You are building Phase 1 of the system specified in `docs/investment-copilot-prd.md`. Read the PRD in full before writing anything. Then read `docs/investment-copilot-ui-flows.md` for screen states.

## Phase 1 scope (read-only)

From PRD §6, Phase 1 only:

1. Rails 8 app, Postgres, Solid Queue, Hotwire, importmap. No SPA, no build step.
2. Schwab OAuth (three-legged) and the full token lifecycle from §5.1: 25-minute access refresh job, 7-day refresh-token expiry tracking, `submission_unknown` and reconciliation are Phase 2 but design the `orders` table for them now.
3. Sync jobs from §5.3: accounts, positions, balances, orders, transactions. Market calendar from Schwab's market-hours endpoint; no hardcoded market hours.
4. Data model from §5.2, all tables, including `instruments` keyed by CUSIP, `trade_legs`, `audit_events`, and flow-adjusted `snapshots`. Migrations complete even for tables Phase 1 doesn't populate.
5. Journal auto-population from fills using the zero-to-zero trade definition; orphan fills land in `incomplete` state.
6. Dashboard with all four banner states (healthy / token expiring / token expired / halted). Halted can be reached via a manual flag in Phase 1 since no guardrails run yet.
7. MCP server (read tools only, §5.5) over HTTPS with bearer auth.
8. Scheduled runtime (§5.5a): Solid Queue jobs calling the Anthropic Messages API with read-only tool definitions, hard tool-turn cap, email output. Implement the 07:00 brief and 16:30 EOD; Sunday review can be a stub that emails the re-auth link and token age.
9. Shadow mode flag exists and is on (nothing to submit yet, but the flag, the audit event, and the UI indicator ship now).
10. Memory repo read access: the app pulls a git repo path on a schedule and exposes its markdown files to the scheduled runtime's prompt.

Not in Phase 1: guardrail engine, proposals, approval UI, order submission, bracket stops, allocation module, FMP. Do not scaffold them beyond the migrations.

## Constraints

- **No live Schwab calls in tests.** VCR/WebMock cassettes only, scrubbed of tokens and encrypted account values. A `FakeSchwab` adapter backs Playwright and dev seeds.
- **Never log or store plaintext account numbers.** Encrypted values from `/accounts/accountNumbers` only. Brakeman must pass.
- **Tokens encrypted at rest** with Active Record Encryption. App key/secret from ENV (dokku config vars).
- **Instrument identity is CUSIP.** No table stores a bare ticker as a foreign key.
- **Every "logged" action is an `audit_events` row.** Re-auth, token refresh failures, shadow-mode toggles, manual halt flag.
- Schwab account access is approved and the app is registered (status pending Ready For Use). Production host is a dokku app on GC2 at `desk.athayde.com`; callback is `https://desk.athayde.com/schwab/callback`; `SCHWAB_APP_KEY`, `SCHWAB_APP_SECRET`, and `SCHWAB_CALLBACK_URL` already exist as dokku config vars, so read exactly those names from ENV. Build the client against the schwab-py order-builder docs and community client libraries for response shapes; isolate every Schwab-shape assumption in the adapter layer so official schemas can replace them without touching callers. The live OAuth test waits on Ready For Use; everything else does not.
- iOS is a Phase 2 Hotwire Native app (PRD §5.8a). In Phase 1, keep every screen mobile-responsive and avoid patterns that fight a native wrapper (no full-page JS routers, no modals that depend on hover).

## Conventions (house standard)

- RSpec full suite. Priority order from PRD §5.11: token lifecycle with time travel, sync jobs with fixture payloads including dividends and corporate actions, journal linking (scale-in/out, orphan fills, ticker change on the same CUSIP), MCP tool contracts.
- Playwright for the clickable UI: dashboard in all four banner states against seeded data, MCP auth failure page, re-auth success/failure.
- `bin/ci` runs in order: rubocop, rspec, brakeman, `bin/importmap audit`, `bundle exec bundle-audit check --update`, Playwright. Fail fast.
- Idiomatic Rails per the DHH skill: thin controllers, models that do the work, no service-object ceremony unless there is a real reason. Run the DHH skill as a review pass at the end of the phase.
- Deploy target: dokku on Ubuntu 24. Include `Procfile`, `app.json` if needed, and a `bin/dokku-setup` script documenting the Postgres/letsencrypt/config-var steps.

## Working method

1. Start by writing `docs/phase-1-plan.md`: the migration list, job list, MCP tool list, and the order you'll build in. Stop and show it before writing code.
2. Build vertically: migrations → Schwab adapter with cassettes → OAuth + token jobs → sync jobs → journal builder → dashboard → MCP → scheduled runtime. Green `bin/ci` at each step.
3. When a Schwab response shape is unknown, mark it `# SCHWAB_SHAPE_UNVERIFIED` in the adapter and list it in `docs/verify-on-approval.md` alongside the two items already in PRD §9.
4. Do not invent Schwab endpoint behavior. If the docs and community clients disagree, note both and pick the conservative reading.
5. Ask before: adding a gem outside Rails defaults, changing a table defined in §5.2, or any deviation from the PRD.
