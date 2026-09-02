**Findings**

1. **Race: halt lock can be bypassed**  
   [risk_rules_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/risk_rules_controller.rb:15) checks `halted?` before calling `supersede!`, outside any lock. A halt can engage after the check and before the new version is written, allowing an edit during a halt without an override reason.  
   Proposed fix: recheck `SystemSettings` under a row lock in the same transaction as the rule supersede, or move the halt/override check into `RiskRule#supersede!`.

2. **Race: concurrent rule edits can create duplicate/stale versions or 500s**  
   [risk_rule.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/risk_rule.rb:24) deactivates the current rule and creates `version + 1` without locking the source row. Two approvers editing the same active rule can both compute the same successor version; depending on indexes, this can produce duplicate version attempts or an unhandled constraint exception.  
   Proposed fix: `lock!` the active rule before superseding, verify it is still active, compute the next version while locked, and handle stale/constraint failures with a controlled error.

3. **Audit omits mode changes**  
   [risk_rules_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/risk_rules_controller.rb:18) allows `mode` to change, but [risk_rule.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/risk_rule.rb:28) audits only `before: self.params` and `after: params`. A `warn`/`block` change is a rule edit but is not captured in before/after evidence.  
   Proposed fix: audit structured before/after payloads, e.g. `{ params:, mode: }` for both old and new versions.

4. **Preview is not limited to today’s waiting proposals**  
   [risk_rules_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/risk_rules_controller.rb:30) previews against `OrderProposal.validated.order(:id)` with no “today” filter. The requirement is today’s waiting proposals, so historical validated proposals can affect the preview output.  
   Proposed fix: use the app’s waiting-proposal scope plus a `created_at`/relevant waiting timestamp filter for `Time.zone.today.all_day`.

5. **Shadow toggle is not atomic with its audit and is not locked**  
   [system_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/system_controller.rb:24) reads state, [system_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/system_controller.rb:31) updates it, then [system_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/system_controller.rb:32) writes the audit separately. Concurrent toggles can make decisions from stale state, and an audit failure after the update leaves an unaudited mode change.  
   Proposed fix: wrap the confirmation decision, `settings.update!`, and `AuditEvent.log` in a transaction with `settings.with_lock`.

6. **Mode param handling can crash and is over-broad**  
   [risk_rules_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/risk_rules_controller.rb:18) accepts raw `params[:mode]` for any rule. The view only exposes mode for `wash_sale`, but a direct request can submit mode for other rules; an invalid enum value can raise outside the `RecordInvalid` rescue.  
   Proposed fix: permit mode only for rule types that support it, validate against `RiskRule.modes.keys`, and return a normal alert on invalid input.

No tests run; this was a read-only review per the prompt.
