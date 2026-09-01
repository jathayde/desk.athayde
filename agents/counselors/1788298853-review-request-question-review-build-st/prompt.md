# Second Opinion Request

## Question
# Review Request

## Question
Review build step 2 of Phase 1: the complete data model (21 tables) for the Investment Copilot, implemented as migrations and Active Record models with model specs. Check it against the plan and the PRD, and against what Phase 2 will need, since the point of shipping every table now is that Phase 2 never alters one.

## Context

### Files to Review
Uncommitted on top of the step 1 commit; `git status --porcelain` shows the set.
- Migrations: @db/migrate/ (20260901220001 through 20260901220020) and the dump @db/structure.sql
- Models: @app/models/account.rb @app/models/instrument.rb @app/models/position.rb @app/models/balance.rb @app/models/order.rb @app/models/order_proposal.rb @app/models/submission_attempt.rb @app/models/transaction.rb @app/models/trade.rb @app/models/trade_leg.rb @app/models/setup.rb @app/models/risk_rule.rb @app/models/snapshot.rb @app/models/audit_event.rb @app/models/market_day.rb @app/models/sync_run.rb @app/models/agent_run.rb @app/models/tool_call.rb @app/models/system_settings.rb @app/models/schwab_token.rb
- Specs: @spec/factories/core.rb @spec/models/audit_event_spec.rb @spec/models/instrument_spec.rb @spec/models/position_spec.rb @spec/models/trade_spec.rb @spec/models/system_settings_spec.rb @spec/models/schwab_token_spec.rb

### Design being implemented
- @docs/phase-1-plan.md §1 (migration table, column by column), §4 (journal builder rules), §5 (stops and open risk), §6 (snapshot math)
- @docs/artifacts/investment-copilot-prd.md §5.1 (idempotent submission, submission_unknown), §5.2 (tables), §5.4.2 (bracket stops, parent_order_id, cancel/replace, unprotected), §5.12 (deferred allocation tables, not built)

## Instructions
You are providing an independent review. Be critical and thorough.
- Check every table against plan §1 and PRD §5.2: missing columns, wrong types or precisions, missing indexes or uniqueness, foreign keys that should or should not cascade, nullability that will bite sync jobs
- Check that Phase 2 can be built without an ALTER on orders, order_proposals, submission_attempts, trades, trade_legs, risk_rules, or audit_events; name the specific column you would need
- Check the append-only guarantee on audit_events: trigger, model, and whether anything (truncate, schema load, Rails internals) bypasses it in a way that matters
- Check instrument identity: partial unique indexes on cusip and schwab_instrument_id, the validation, predecessor linkage, symbol history shape
- Check Position#distance_to_stop and #open_risk semantics against plan §5 (unprotected must be nil, never zero)
- Check enum values and scopes for collisions with Active Record (the Trade `open` scope, the `Transaction` class name, `exit` as an enum value) and say whether any should be renamed
- Check the Active Record Encryption setup on schwab_tokens
- Flag model methods that are missing for step 3 through 6 to be clean, and anything present that is premature
- Be direct and opinionated; do not hedge; order findings by severity with file paths

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
