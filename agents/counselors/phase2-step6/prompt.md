Review Phase 2 step 6 of AthaydeDesk (Rails 8.1): the rule editor and the shadow-mode toggle. Read only these files and their specs:
- app/controllers/risk_rules_controller.rb, app/views/risk_rules/index.html.erb, app/views/risk_rules/preview.html.erb
- app/controllers/system_controller.rb (the new `shadow` action), app/views/system/show.html.erb (the shadow form)
- config/routes.rb (risk_rules and system routes)
- app/models/risk_rule.rb (supersede!, REQUIRED_PARAMS), app/models/system_settings.rb, app/models/guardrails/rule.rb
- spec/requests/risk_rules_spec.rb
Requirements from docs/phase-2-plan.md §8: every rule edit is a new version (supersede!), audited as rule_changed with before/after; effect preview over today's waiting proposals without writing anything; the editor is locked while a halt is engaged except through an override reason recorded on the new version; approver-only; shadow-mode toggle with a typed confirmation and a reason, audited as shadow_mode_toggled with the shadow evidence (shadowed approvals, reconciled count), setting shadow_mode_changed_at. Report concrete defects (security, correctness, missing audit, races, param handling), each with file:line and a proposed fix. Do not restyle. Do not review other files.
