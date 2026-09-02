# Review Request

## Question
Review Phase 2 step 1 of Investment Copilot (uncommitted on top of commit 48bfe89; `git status --porcelain` lists the files): the proposal state machine and its database invariants, the two halts, the approver, audited write tools, rule versioning, sizing, and the state table the transition specs are written from. Under 600 words.

## Files
@docs/phase-2-plan.md (§0, §1, §2, §11) @docs/phase-2-state-table.md @db/migrate/20260902120001_phase_two_prerequisites.rb @app/models/order_proposal.rb @app/models/submission_attempt.rb @app/models/risk_rule.rb @app/models/guardrails.rb @app/models/sizing.rb @app/models/system_settings.rb @app/models/watchlist_item.rb @app/models/agent/tool.rb @app/models/agent/tools.rb @app/models/audit_event.rb @app/controllers/application_controller.rb @db/seeds.rb
Specs: @spec/models/order_proposal_spec.rb @spec/models/sizing_spec.rb @spec/models/risk_rule_spec.rb @spec/models/system_settings_halts_spec.rb @spec/models/agent/tools_spec.rb

## Instructions
Independent and critical. Does every row of the state table have a transition and a spec, and does every transition refuse the wrong source state? Can two attempts exist for one proposal under any interleaving (the partial unique index and `start_submission!`)? Is anything able to move a proposal back to an approvable state? Does the halt split match PRD §5.4 3 and Flow 8? Is the audit trail complete and honest about actors? Is `Sizing` right (floor, whole shares, refusal reasons, BigDecimal)? Is the registry's audit row for write tools sufficient, and can a write tool reach the scheduled transport? What must change before commit versus at step 3?
