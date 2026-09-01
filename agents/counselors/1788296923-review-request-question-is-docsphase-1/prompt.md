# Second Opinion Request

## Question
# Review Request

## Question
Is `docs/phase-1-plan.md` a faithful, complete, and well-designed reading of Phase 1 of the Investment Copilot PRD? Find gaps, contradictions, and design decisions that will have to be undone in Phase 2. The PRD is the source of truth; where the kickoff brief and the PRD disagree, the PRD wins.

## Context

### Files to Review
- @docs/artifacts/investment-copilot-prd.md (PRD v9, source of truth)
- @docs/phase-1-plan.md (the plan under review)
- @docs/artifacts/claude-code-kickoff.md (Phase 1 scope brief and constraints)
- @docs/artifacts/investment-copilot-ui-flows.md (screen states; Phase 1 needs dashboard banners, re-auth, health, journal quick entry)

### State of the repo
A freshly generated Rails 8.1 app (Postgres, Solid Queue, Hotwire, importmap), no application code yet. The plan is the only design document. No Schwab API access yet (app registration pending), so every Schwab response shape is an assumption drawn from community client libraries such as schwab-py.

### Phase 1 scope reminder
Read-only: Schwab OAuth + token lifecycle, sync (accounts, positions, balances, orders, transactions, market hours), journal auto-population from fills using the zero-to-zero trade definition keyed by CUSIP, dashboard with four banner states, MCP read tools over HTTPS with bearer auth, scheduled Anthropic Messages API runs (07:00 brief, 16:30 EOD, Sunday stub) with read-only tools and a hard tool-turn cap, shadow-mode flag, memory-repo pull. Migrations for every §5.2 table even where Phase 1 does not populate them. Not in Phase 1: guardrails, proposals, approval UI, submission, brackets, allocation module, FMP.

## Instructions
You are providing an independent review. Be critical and thorough.
- Read the referenced files to understand the full context
- Check the plan's migrations against PRD §5.2 column by column: missing tables, missing columns, columns that will force a Phase 2 schema change, wrong key choices (instrument identity must be CUSIP, account identity must be the encrypted hash, never a plaintext number)
- Check the token lifecycle design against §5.1 and §5.10 (25-minute refresh, 7-day hard expiry, degrade-and-queue rather than skip, Sunday ritual and Mon/Tue escalation)
- Check the journal builder rules against §5.2 `trades`/`trade_legs` and the corporate-action, dividend, scale-in/out, orphan-fill, and ticker-change cases
- Check the sync cadence and market-calendar design against §5.3
- Check the MCP and scheduled-runtime design against §5.5 and §5.5a: one tool registry, two transports, unattended runs read-only with a turn cap
- Check the flow-adjusted snapshot math against §5.2 `snapshots`
- Flag any Schwab endpoint behavior the plan assumes without evidence
- Flag anything the plan builds that the PRD explicitly defers, and anything the PRD requires in Phase 1 that the plan omits
- Identify risks, tradeoffs, and blind spots; suggest alternatives if you see better approaches
- Be direct and opinionated; do not hedge
- Structure your response with clear headings, and order findings by severity

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
