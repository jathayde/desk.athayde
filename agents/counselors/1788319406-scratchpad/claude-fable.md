**Verdict.** The plan matches the PRD in shape, but it has one crash window that duplicates an order, one workflow where the operator will duplicate by hand, and a halt gate that contradicts PRD §5.4 3. Fix the state machine and the submission transaction on paper before step 1.

**Critical**

1. **The attempt row lives inside the lock transaction.** §5 locks the row, writes `submission_attempts`, then calls Schwab. A worker killed during the call rolls the attempt back and leaves the proposal `approved` with no evidence anything was sent. The next tap sends it again. Add a `submitting` state. Transaction one: lock, `approved → submitting`, insert the attempt, commit. Then the HTTP call with explicit short timeouts. Transaction two: the outcome. A `submitting` row older than the timeout is swept to `submission_unknown`, never back to `approved`. Nothing re-enters `approved` from `submitting` or `submission_unknown`.

2. **"Reconcile found nothing" is not a retry licence, and "unknown" invites a manual duplicate.** Schwab may list the order seconds after a POST that timed out. Reconcile must wait a quiet period and confirm twice before anything is resubmittable. While any proposal on an instrument is `submitting` or `submission_unknown`, every other proposal on that instrument hard-fails as "pending reconciliation", including the manual form. Otherwise the operator reads "unknown, check Schwab", re-proposes, approves, and the system does the one thing §10 says it cannot afford. The matcher must exclude orders already linked to a proposal and treat two matches as ambiguous for the operator, not as found.

3. **A 201 with no parsable `Location` is `submission_unknown`.** The plan names only the 4xx and timeout branches. The broker order id goes on the proposal in transaction two; the sync links by that id, since Schwab carries no proposal id.

4. **Approve and submit are conflated but undefined.** Flow 2 says the confirm is the moment the order goes to Schwab. §4 has `approve!`, §5 has `Submit`. Decide: one synchronous request, operator waits for the outcome. A job in between adds a state nobody watches.

**High**

5. **The halt gate contradicts PRD §5.4 3.** `writes_allowed?` is `!shadow_mode && !manual_halt`, and §5 uses it as the real-path gate, so exits are blocked during a halt. Flow 1 says exits stay available. The PRD also separates rule halts from the kill switch (Flow 8 stops everything); Phase 1 collapsed both into "Halt". Split them, and give rule halts durable state (rule, tripped at, resets at) with one `halt_tripped` audit and one email. A per-evaluation result cannot drive the banner or the rule-editor lock.

6. **Sizing must be frozen at create.** §2 re-evaluates on approve with fresh context. If quantity is recomputed, the operator approves an order they did not see. Rules run over the frozen quantity; a changed context refuses with "re-propose". Entries should be LIMIT only in Phase 2: collar, sizing, and notional cap against a quote for a MARKET order are fiction.

7. **Settled cash projects the wrong set.** With approve = submit, nothing sits in `approved`. Subtract `submitting`, `submission_unknown`, and unfilled `submitted` buys. Whether `cashAvailableForTrading` already nets working buys is unverified (item 10 is also open), so double-subtract until it is. A balance past the staleness threshold makes rule 4 `unavailable`, and `unavailable` on rule 4 is a hard fail.

8. **Exits collide with the bracket child.** A sell proposal on a position with a working stop leaves an oversized stop at Schwab. The exit approval must reduce or cancel the child in the same step. Absent from the plan.

9. **Wash sale reads the IRA backwards and only one direction.** IRA losses have no tax effect. What matters is an IRA buy within 30 days either side of a taxable loss. And the window runs both ways: a loss sale with a buy in the prior 30 days, in either account, is washed. On a buy, look back for taxable losses. On a sell that realizes a loss, look back for buys in both accounts. IRA buys after a taxable loss go to the brief and the trade, since nothing can block them.

10. **Shadow reconciliation is undefined, so the count is meaningless.** PRD §5.9 wants shadowed approvals reconciled against what would have been sent. Define it: the operator places the order by hand, the sync ingests it, and the matcher from item 2 links the `would_have_submitted` attempt to the Schwab-direct order and diffs the payload against Schwab's returned shape. That exercises the matcher and the bracket shape before either guards money.

**Medium**

11. **Enum gaps.** Add `submitting`, `rejected_by_rules`, `expired`. Expiry applies to `proposed` and `validated` only. `guardrail_results` snapshots params, not just rule id and version.

12. **Two users can log in.** Restrict approval to a named approver, or a second inbox is an order path.

**Schwab before step 4.** At zero risk: place one bracket by hand on Schwab's site, let the sync ingest it, and read the strategy type, child shape, child status, and `taxLotMethod`. Probe `previewOrder`; if it exists the payload builder is checkable without an order. The `Location` header, write limits, and replace semantics on a TRIGGER child need the first live submission: a one-share first-live runbook, operator watching. Evaluator, collar, sizing, wash sale, queue, and mailer all shadow safely.

**Build order.** Move sizing into step 1; rule 1 is meaningless without it. Move the payload builder and the shadow branch into step 3 so every approval from then on yields a payload to reconcile. Step 4 becomes the real client path, reconcile, and the instrument lock. Add a step 0: a state table (state × action × result, including crash points) that the §5.11 transition specs are generated from.

**Before step 1:** items 1, 2, 4, 5, 6, and 11 change the schema and state machine and must be in the plan first. Items 7 to 10 can land at their steps but should be written down now.
