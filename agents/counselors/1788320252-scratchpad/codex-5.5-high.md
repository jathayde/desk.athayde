Findings, ordered by severity:

1. [order_proposal.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/order_proposal.rb:101): source-state checks are object-memory checks, not database checks. A stale instance can still pass `from.include?(status)` and `update!` the row after another process moved it forward. That can resurrect a proposal into `validated` via `evaluate!`, or rewrite submission states. This breaks “wrong source state refuses” under interleaving and must be fixed before commit with row locking/reload or conditional updates.

2. [order_proposal.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/order_proposal.rb:64): `start_submission!` is not atomic. It writes `submitting` and `proposal_approved` before creating the attempt. If attempt creation fails, including from the partial unique index, the proposal can be left `submitting` with no attempt and a dishonest audit trail. The first transaction belongs in this method or a step-3 service, but the invariant/spec should not imply it is already safe.

3. [order_proposal.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/order_proposal.rb:96): `record_broker_outcome!` accepts arbitrary targets. Passing `:validated` updates the row before `AuditEvent` validation fails, so it can move a submitted proposal back to approvable. Restrict to `filled`/`cancelled` and make transition plus audit transactional.

4. [db/structure.sql](/Users/jathayde/Development/Personal/desk.athayde/db/structure.sql:334): documented DB invariants are incomplete. There is no database enforcement that `submitted`/`filled`/`cancelled` has an attempt; the partial unique index only prevents multiple live attempts. If this is only a model/service invariant until step 3, the docs should say that.

5. [order_proposal_spec.rb](/Users/jathayde/Development/Personal/desk.athayde/spec/models/order_proposal_spec.rb:1): specs are not truly generated row-by-row from the state table. Missing or shallow coverage includes create/`proposal_created`, sweep from stale `submitting` to `submission_unknown`, ambiguous reconcile no-op, cancelled broker outcome, every terminal refusing every action, and stale-instance/concurrency refusals.

6. [application_controller.rb](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/application_controller.rb:4): approver enforcement exists only as a controller helper. The state-changing model methods accept any user, and there is no spec that non-approvers cannot reject/submit/override. That is a commit blocker if these methods are intended as the invariant boundary.

7. [system_settings.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/system_settings.rb:8): halt split matches the PRD directionally: rule halt blocks entries, manual halt blocks everything. But `trip_rule_halt!` is not locked, so two evaluators can both audit/update. Sequential idempotence is covered; interleaving is not.

Sizing is mostly right on floor/whole shares/BigDecimal behavior, though explicit refusal for nonpositive rule percent would make the invariant cleaner.

Write tools cannot reach scheduled transport through the registry today. The audit row is useful but thin: it records arguments before validation/invocation and omits success/error linkage. Good enough for step 1 metadata, not enough for final audited writes.
