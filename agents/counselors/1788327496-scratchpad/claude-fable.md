**Verdict:** no path sends the order twice, and the id is never guessed. Five things must change before commit; they are all in the failure orders, where the row goes terminal or quiet while the broker state disagrees.

**Must change before commit**

1. **The reconcile job believes an absence over a failed sync.** `SyncRun.record` swallows every `Schwab::Error` and finishes the run as failed or skipped (`app/models/sync_run.rb:31`), so the `perform_now` at `reconcile_job.rb:14` returns quietly on a 5xx, a 429, or a paused token. The matcher then reads stale rows and records an absence. Two outages ten minutes apart mark the attempt `not_placed`, the operator re-proposes, and the order goes in twice. A partial run or one with `orders_unmapped` or `orders_unresolved` quarantine has the same effect, and the quarantined order can be the very one placed. Capture the run, count an absence only when it succeeded with no order quarantine, otherwise re-schedule after the gap.

2. **Non-Schwab failures strand the row.** `SyncRun.record` re-raises `StandardError` (line 37), the job has no `retry_on`, and nothing else ever enqueues a reconcile for a `submission_unknown` row. One `RecordNotUnique` from the tick's orders sync running alongside the `perform_now` leaves the instrument locked forever.

3. **Ambiguous is a dead end.** After `note(attempt, "ambiguous")` nothing re-enqueues. When the operator cancels the extra at Schwab, nobody looks again. Re-schedule after the gap; the matcher already excludes dead statuses, so the next look finds one.

4. **An exit's failure orders leave the position naked and nobody says so.** Two paths in `place.rb`:
   - Cancel lands, then the sell gets a 4xx. `record_rejected!` goes terminal with Schwab's message; the stop is gone and the reason does not mention it.
   - Cancel or replace times out. The rescue records unknown and enqueues a reconcile that searches for the *sell payload*, which was never sent. Ten minutes later: `not_placed`. The stop may be cancelled.
   
   The protection watch will not catch either: `expected_protection?` needs a filled app entry or a `GONE` stop, and a cancelled stop is refetched by id and upserted `CANCELED`. Fix: an unknown from the stop step is "sell not sent, stop state unknown" and should fail immediately with that reason, not enter reconciliation; the rejected reason should name the stop action that landed; and `expected_protection?` should include any proposal on the instrument with a `child_action`.

5. **The watch misses PRD §5.4.2's main case.** A GTC stop cancelled out-of-band is outside the cursor window, refetched by id, and stored `CANCELED`, never `GONE`. So "a stop that disappears at the broker" alerts only when Schwab 404s. Widen the second clause to `DEAD_STATUSES + [GONE]`.

6. **`Place` rescues five classes and nothing else.** `AuthError` after the refresh, `ReauthRequired` or `NoUsableToken` from `Schwab.client` before any request, `NotConfigured`, and an `IllegalTransition` from the sweep race all leave the row `submitting` with a 500 on the approve page, and the sweep then mails "unknown" for an order that was never sent. A 401 accepts nothing, so those are `record_rejected!` with "not sent". Rescue `Schwab::Error` as the floor.

**At step 5**

- The sweep's two-minute clock is under the real branch's worst case: two writes, each up to 25 s plus a refresh plus 25 s. A late `record_submitted!` then raises and drops the id (the matcher may recover it). Let it accept from `submission_unknown`, or lengthen `STALE_AFTER`.
- A 429 and the local budget refusal accept nothing, yet cost a lock, an alert, and eleven minutes. Classify as not sent.
- `record_reconciled!` links the order outside the proposal transaction; a raise leaves an order pointing at a proposal with no id.
- `replace_order` returns the new stop id and `adjust_stop` discards it; put it in the audit data.
- The mail says "no working stop" for `:partial`, `:awaiting`, `:trailing_unknown`, and `:unpriced`. An entry with a trailing stop would mail daily. Say the state.
- The fake's `order(hash, id)` does not search `@placed`, so a refetch of a fake-placed stop 404s into `GONE`.
- `link_shadows` runs inside the reconcile's sync, before the matcher, and can take the same order for a shadow row on the instrument.

**What holds:** one POST per attempt and no path re-sends. The 401 refresh-and-retry is safe: nothing is accepted on a 401, `refresh!` runs under the row lock outside transaction one, and the dup'd request carries the body. A missing Location is unknown, not a guess. The sweep branches on the frozen `shadow` flag, which is right for both cases. The matcher excludes linked and dead orders, the window covers clock skew, and the gap arithmetic is correct.
