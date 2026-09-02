Review Phase 2 step 7 of AthaydeDesk (Rails 8.1): notifications and screens. Read only these files:
- app/mailers/alert_mailer.rb, app/views/alert_mailer/new_proposal.text.erb, fill_or_cancel.text.erb, halt_tripped.text.erb
- app/models/proposals/create.rb (the new_proposal hook), app/models/order_proposal.rb (record_broker_outcome!, record_unknown!), app/models/system_settings.rb (trip_rule_halt!)
- app/models/failure_digest.rb, app/views/brief_mailer/failure_digest.text.erb
- app/models/desk.rb (banner, secondary_statuses, pending_proposals, unresolved_submissions, unprotected_rows), app/views/dashboard/_banner.html.erb, app/views/dashboard/_glance.html.erb
- app/models/agent/context.rb (todays_proposals), app/models/agent/prompts/eod.md.erb
- lib/playwright/scenario.rb (proposal_warn, proposal_blocked, proposal_override, submission_unknown, rule_halted)
- spec/mailers/alert_mailer_spec.rb, spec/models/desk_spec.rb
Requirements from docs/phase-2-plan.md §9: AlertMailer new_proposal (agent proposals), fill_or_cancel (from the sync's broker outcome), halt_tripped (rule halt, one audit and one email); digest carries failed submissions; dashboard shows a pending-proposals line and the unprotected and submission-unknown banners; the EOD brief links fills to proposals; scheduled runs stay read-only; every mail is sent after the state it reports is committed. Report concrete defects (mail sent inside an uncommitted transaction, duplicate or missing mails, wrong banner precedence, N+1 on the dashboard, prompt injection surface in the EOD recap, spec gaps), each with file:line and a proposed fix. Do not restyle.
