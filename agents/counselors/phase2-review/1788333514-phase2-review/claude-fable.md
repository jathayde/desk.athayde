Review done. I read the six files named and nothing else. Findings below, in order of severity.

**1. A late order id after the reconcile's "not placed" verdict leaves a working order on a terminal row, and that unlocks a second submission.** The code at `app/models/submission/place.rb:29-34` already expects this ordering but handles it by swallowing the transition.

- T0: approve commits `submitting` plus a pending attempt (`app/models/submission/submit.rb:45`, `app/models/order_proposal.rb:121-131`). The worker then sends the order (`place.rb:20`) but is paused, or has not yet sent it and is paused.
- T+5m: the sweep moves the row to `submission_unknown` (`order_proposal.rb:60`) and enqueues a reconcile with no quiet period (`order_proposal.rb:61`).
- T+5m: first look. The sync is whole, the order is not in the feed. The attempt records first absence (`app/jobs/submission/reconcile_job.rb:34`).
- T+15m: second look. The order is still absent, so `record_not_placed!` runs (`reconcile_job.rb:31-32`, `order_proposal.rb:165-169`). The row is `submission_failed`, which is not in UNRESOLVED (`order_proposal.rb:32`), so the instrument unlocks.
- T+16m: the worker resumes and gets an id, or sends now and gets an id. `record_submitted!` allows only `submitting` and `submission_unknown` (`order_proposal.rb:142`), so it raises. The rescue at `place.rb:29-34` writes the id onto a `submission_failed` row and logs `proposal_submitted`. Status, label ("not placed"), and `failure_reason` ("confirmed not placed") all still say nothing was placed.
- The operator re-proposes as the table tells them to (`docs/phase-2-state-table.md:21`). The check at `order_proposal.rb:123` finds no unresolved row and the second order goes to Schwab. When the first order fills, `record_broker_outcome!` refuses because the row is not `submitted` (`order_proposal.rb:194`), so the fill never reaches the proposal.

This needs the approve thread to survive roughly STALE_SUBMITTING plus CONFIRMATION_GAP. That is a stopped-and-resumed process, or a Schwab client with no read timeout. I could not check the client's timeouts within the files allowed. The same end state, minus the id, arises if the matcher misses a real order on two whole looks. That depends on the matcher, which was also outside the read list.

Fix, two parts:

```ruby
# order_proposal.rb:141 — a late id is authoritative over the reconcile's verdict too
def record_submitted!(attempt, broker_order_id:)
  from = attempt.not_placed? ? %w[ submitting submission_unknown submission_failed ] : %w[ submitting submission_unknown ]
  outcome!(attempt, from: from, to: :submitted, ...)
```

```ruby
# place.rb:19 — a worker that wakes after the sweep does not send; the row is already unknown and the reconcile will say not placed
raise Superseded unless @proposal.reload.submitting?
```

Then delete the rescue at `place.rb:29-34`. It is the thing that hides the working order. Add `submission_failed (attempt not_placed)` to the From column of table row 15 and carve it out of row 24.

**2. A definitive answer after the sweep is thrown away as a 500.** In Ruby an exception raised inside a rescue clause is not caught by a sibling clause. So when the sweep has already moved the row to `submission_unknown` and the in-flight call then returns a 4xx, `record_rejected!` raises IllegalTransition from inside the rescue at `place.rb:27-28` and it propagates out of Submit to the controller. The 4xx said nothing was placed. The operator instead waits ten minutes for the reconcile to say the same, and sees an error meanwhile. Same for a MAYBE_SENT error at `place.rb:24-26`, though there the state is already right.

Fix: let `record_rejected!` accept `submission_unknown` as well (`order_proposal.rb:159`). Place never retries, so this call is the only call and its 4xx is final. The reconcile job's first line then exits cleanly.

**3. One race aborts the whole sweep tick.** `sweep_submitting!` (`order_proposal.rb:54-64`) has no per-row rescue. If a worker's `record_submitted!` or `record_shadow!` commits between the query and the sweep's own transition, IllegalTransition propagates and every remaining stale row waits for the next tick. Fix: rescue IllegalTransition per row inside the loop and continue.

**No other double-send path exists in these files.** Two approves serialise on the row lock and the second is refused as not approvable (`submit.rb:30-32`). The reconcile job never places. The reconcile's `record_not_placed!` and a concurrent late id both re-read under the lock (`order_proposal.rb:211-212`), so whichever commits second raises, and the raise only causes harm in the ordering described in item 1.

**Not verified, outside the read list:** how the matcher's REAL_WINDOW is anchored (attempt time or now), whether Orders::ProposalLink tolerates a broker_order_id on a `submission_failed` row, and whether it moves a proposal reconciled after its order already filled.
