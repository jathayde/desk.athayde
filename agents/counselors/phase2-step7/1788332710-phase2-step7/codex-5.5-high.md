**Findings**

1. **High: rule-halt alert is enqueued inside the uncommitted halt transaction.**  
   [app/models/system_settings.rb:26](/Users/jathayde/Development/Personal/desk.athayde/app/models/system_settings.rb:26) and [app/models/system_settings.rb:31](/Users/jathayde/Development/Personal/desk.athayde/app/models/system_settings.rb:31) call `deliver_later` inside `with_lock`. That can enqueue/send an alert before the `rule_halt_*` fields and audit row are committed.  
   Proposed fix: set a local `mail = { rule:, reason:, resets_at: }` flag inside the lock, then call `AlertMailer.halt_tripped(...).deliver_later` after the `with_lock` block commits.

2. **High: proposal creation does not respect unresolved submission locks.**  
   [app/models/proposals/create.rb:15](/Users/jathayde/Development/Personal/desk.athayde/app/models/proposals/create.rb:15) only blocks existing `proposed`/`validated` proposals. It ignores `submitting` and `submission_unknown`, even though [app/models/order_proposal.rb:32](/Users/jathayde/Development/Personal/desk.athayde/app/models/order_proposal.rb:32) defines those as unresolved instrument locks. This can let a new agent proposal and alert happen while Schwab state is unknown for the same instrument.  
   Proposed fix: include `OrderProposal::UNRESOLVED` in the blocking query, or use a shared scope/constant for “open proposal or unresolved submission” so creation and submission locking agree.

3. **Medium: EOD proposal matching uses `updated_at` as a broker-outcome timestamp.**  
   [app/models/agent/context.rb:44](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/context.rb:44) includes filled/cancelled proposals based on `updated_at: day`. A later unrelated update can make an old broker outcome appear in today’s recap, and a broker outcome timestamp is not represented directly.  
   Proposed fix: query the audit event created by `record_broker_outcome!` (`proposal_filled` / `proposal_cancelled`) or persist a dedicated `broker_outcome_at`/`filled_at`/`cancelled_at` column and query that.

4. **Medium: EOD prompt has a raw prompt-injection surface.**  
   [app/models/agent/prompts/eod.md.erb:6](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/prompts/eod.md.erb:6) interpolates proposal data directly into the model prompt as Markdown text. If any field such as `instrument.symbol` contains newlines or instruction-like text, it can alter the prompt structure.  
   Proposed fix: render proposals as escaped JSON/data, strip CR/LF from symbols, and frame it explicitly as untrusted data.

5. **Medium: EOD scheduled-run read-only behavior is not asserted in this prompt.**  
   [app/models/agent/prompts/eod.md.erb:10](/Users/jathayde/Development/Personal/desk.athayde/app/models/agent/prompts/eod.md.erb:10) says to cover items “only from tool results,” but does not explicitly forbid writes, approvals, proposal creation, or state mutation. If the read-only guarantee is enforced elsewhere, this file does not make it visible.  
   Proposed fix: add a direct read-only instruction to the EOD prompt, and preferably enforce a read-only tool allowlist in the scheduled runner.

6. **Low: alert spec says cancel is covered, but only fill is tested.**  
   [spec/mailers/alert_mailer_spec.rb:27](/Users/jathayde/Development/Personal/desk.athayde/spec/mailers/alert_mailer_spec.rb:27) describes “a fill and a cancel,” but the example only exercises `record_broker_outcome!(:filled)` at [spec/mailers/alert_mailer_spec.rb:29](/Users/jathayde/Development/Personal/desk.athayde/spec/mailers/alert_mailer_spec.rb:29).  
   Proposed fix: add a submitted proposal that records `:cancelled` and assert the cancel subject/body.

7. **Low: no spec covers halt-mail rollback/commit timing.**  
   [spec/mailers/alert_mailer_spec.rb:32](/Users/jathayde/Development/Personal/desk.athayde/spec/mailers/alert_mailer_spec.rb:32) covers the happy-path halt email, but not that the mail is sent only after the halt state and audit commit.  
   Proposed fix: add a transaction rollback test or refactor `trip_rule_halt!` to return a mail-intent and test delivery happens after the lock block.

I did not find a concrete dashboard N+1 in the reviewed files. `unresolved_submissions` includes instruments, `rows` includes instruments/stops, and the proposal counts are memoized.
