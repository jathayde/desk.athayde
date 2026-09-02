# Order proposal state table (Phase 2 step 0)

The transition specs in `spec/models/order_proposal_spec.rb` are written from this table. A row is state × action → result. Every legal transition writes one audit event; every illegal one raises `OrderProposal::IllegalTransition` and writes nothing. Crash points are marked ✕ and say what the next actor sees.

| From | Action (actor) | To | Audit | Notes |
|---|---|---|---|---|
| (none) | create (tool or form, via `Proposals::Create`) | `proposed` | `proposal_created` | sizing and collar frozen on the row at creation |
| `proposed` | evaluate, no hard fail (system) | `validated` | `proposal_evaluated` | results snapshot rule ids, versions, params, numbers |
| `proposed` | evaluate, any hard fail (system) | `rejected_by_rules` | `proposal_evaluated` | terminal; re-propose |
| `proposed`, `validated` | end of the proposal's market day (tick) | `expired` | `proposal_expired` | terminal |
| `validated` | reject (approver) | `rejected` | `proposal_rejected` | terminal; reason required |
| `validated` | approve (approver): transaction 1 = lock, gates, re-evaluate over frozen sizing, acknowledge warnings, override reason | `submitting` + attempt row | `proposal_approved`, `proposal_submitting` | refused with "re-propose" when the re-evaluation would have changed the quantity or turned a pass into a fail; refused (in words by `start_submission!`, and by the partial unique index) when the instrument has a `submitting` or `submission_unknown` proposal |
| `submitting` | ✕ worker dies before the HTTP call | `submitting` | — | the sweep (tick) moves rows older than the timeouts to `submission_unknown`; the operator sees "unknown, check Schwab"; never back to `validated` |
| `submitting` | shadow branch (system) | `submitted` (shadow), attempt `would_have_submitted` | `would_have_submitted` | the operator places it by hand; the matcher links the Schwab-direct order later (`submission_reconciled`) |
| `submitting`, `submission_unknown` | HTTP 2xx with an order id (system) | `submitted`, attempt `submitted` | `proposal_submitted` | `broker_order_id` on the row; the sync links the order by it; a late answer after the sweep is still authoritative |
| `submitting` | HTTP 2xx without a parsable id, timeout, 5xx, dropped connection (system) | `submission_unknown`, attempt `unknown` | `submission_unknown` | reconcile job enqueued; the instrument is locked for every other proposal |
| `submitting`, `submission_unknown` | HTTP 4xx (system, `record_rejected!`) | `submission_failed`, attempt `failed` | `submission_failed` | terminal; the error shown; re-propose. From `submission_unknown` only when the sweep moved the row before the one call was answered; the answer is final |
| `submitting` | ✕ worker dies after the call, before transaction 2 | `submitting` | — | swept to `submission_unknown`; the reconcile job may find the order |
| `submission_unknown` | reconcile finds exactly one unlinked match (job) | `submitted`, attempt `submitted` | `submission_reconciled` | linked by `broker_order_id` |
| `submission_unknown` | reconcile finds two or more (job) | `submission_unknown` | — | "ambiguous" on the queue; the operator resolves at Schwab |
| `submission_unknown` | reconcile finds nothing twice, ten minutes apart, after a 60 s quiet period (job, `record_not_placed!`) | `submission_failed`, attempt `not_placed` | `submission_failed` | terminal; the instrument unlocks; re-propose |
| `submitted` | sync sees the order filled | `filled` | `proposal_filled` | written only by the sync |
| `submitted` | sync sees the order cancelled, rejected, or expired at the broker | `cancelled` | `proposal_cancelled` | written only by the sync; a filled parent with no live child is the unprotected alert |
| `submission_failed` with attempt `not_placed` | a maybe-sent error, late (system, `record_unknown!`) | `submission_unknown`, attempt `unknown` again, audited `late: true`, the reconcile job enqueued after the quiet period | `submission_unknown` | the verdict was about an order the job could not yet see; the row is looked at again |
| `submission_failed` with attempt `not_placed` | HTTP 2xx with an id, late (system, `record_submitted!`) | `submitted`, attempt `submitted`, audited `late: true`, `late_submission` mail | `submitted` | the id is the last fact: the order is working, the sync links it, the fill reaches it; the operator checks for a duplicate |
| any terminal (`rejected_by_rules`, `rejected`, `expired`, `submission_failed` except the late-answer row above, `filled`, `cancelled`) | anything | raises | — | |
| `submitting`, `submission_unknown`, `submitted` | reject, approve, expire | raises | — | nothing leaves the submission path by hand |

Invariants the database enforces: one attempt per proposal whose outcome is not `failed` or `not_placed` (partial unique index); one proposal per account and instrument in `submitting` or `submission_unknown` (partial unique index); `broker_order_id` unique among proposals when present. Attempt outcomes: `pending` (transaction one wrote it and the call has not answered; it is what holds the index between the two transactions), `submitted`, `would_have_submitted`, `unknown`, `not_placed`, `failed`. "A `submitted` proposal has an attempt" is a model invariant kept by the transitions, which write both in one transaction, not a database constraint.
