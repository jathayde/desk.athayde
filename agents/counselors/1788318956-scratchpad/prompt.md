# Review Request

## Question
Review a small post-deploy addition to Investment Copilot Phase 1: an operator-marked "delisted" flag on instruments. Uncommitted on top of commit 7a6b9f1; `git status --porcelain` lists the files. Under 500 words.

## Files
@db/migrate/20260902110001_add_delisted_at_to_instruments.rb @app/models/instrument.rb @app/models/position.rb @app/models/dashboard.rb @app/models/snapshot.rb @app/jobs/sync/positions_job.rb @app/controllers/instruments_controller.rb @config/routes.rb @app/views/system/show.html.erb @app/models/system_status.rb @app/helpers/application_helper.rb @app/models/agent/context.rb @app/models/agent/prompts/system.md.erb @app/models/audit_event.rb
Specs: @spec/models/delisted_holding_spec.rb @spec/requests/system_spec.rb
Design: @docs/phase-1-plan.md §5 (stops) and the "Delisted holdings" paragraph in §11.

## Instructions
Independent and critical. Check: every consumer of protection states (dashboard rows, excluded summary, snapshot unprotected_count, tools, brief, Playwright labels) handles :delisted; the auto-relist rule in the positions sync (last_price positive) cannot flap or fire on a stale market value; the controller's authorization and CSRF; whether a delisted holding should also leave open trades' review flags or the journal; and what the morning brief will say about it. Say what must change before commit.
