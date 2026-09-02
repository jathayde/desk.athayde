Findings are in hand. Writing the review now.

## Verdict

The path is sound where it matters: the same-row double approve is refused by the lock plus the `approvable?` re-read, a blocking re-evaluation rolls transaction one back and engages the halt outside it, the shadow branch leaves `submitted` with `shadow` true, a `would_have_submitted` attempt, and the three audits in order, and fills and cancels are written only from synced order rows scoped to `submitted`. Four things should change before commit.

## Before commit

- **Playwright reset leaves attempts behind.** `Playwright::Scenario.reset!` deletes proposals but not `SubmissionAttempt`, and the attempts table has a foreign key to proposals. After the approve test, the next scenario load in system.spec.js will raise a foreign-key violation. Add `SubmissionAttempt` before `OrderProposal` in the list at `lib/playwright/scenario.rb:21`.
- **Shadow-off is checked after transaction one commits.** In `Submission::Submit#call` the "not built yet" refusal runs after the row is already `submitting` with a pending attempt. That locks the instrument with no sweep until step 4. Read settings once under the lock and refuse before `start_submission!`. The spec assertion at `spec/models/submission/submit_spec.rb:58` should flip to `validated`.
- **A new warning is a dead end.** The acknowledgement check uses the fresh report, but a refusal rolls back the persisted results, so a warning that appeared since creation has no checkbox on the page. Treat a fresh warning not in the stored set as "the desk changed; re-propose", which is what the plan's re-evaluation rule already says.
- **Decided list order.** `decided_at DESC` puts nulls first in Postgres, so expired and rules-rejected rows always sit above human decisions. Order by id.

## Answers to the questions

- **Duplicates.** The same row cannot be approved twice. Creation is unguarded: two tabs, or the tool and the form, produce two `validated` proposals for the same instrument and side, and in shadow both can be approved when cash allows. The matcher then hands the one hand-placed order to the lower id and the other sits at "approved, shadow" forever. Decide the same-instrument policy at step 4, before a real call can place two orders.
- **Matcher.** It cannot link twice: linked orders are excluded and the proposal must still lack a broker id. It is status-agnostic, so a hand-placed order that is cancelled and re-placed yields two candidates and stays ambiguous with no screen saying so and no manual link. `REPLACED` counts as cancelled, so an operator who replaces the hand-placed order moves the proposal to `cancelled` while the replacement works. Both belong with the reconcile job at step 4.
- **Payload.** It matches schwab-py's `first_triggers_second`: TRIGGER parent, SINGLE child under `childOrderStrategies`, the equity leg shape, session and duration, and `taxLotMethod` at the top level. schwab-py sends prices with two decimals, so use a fixed two-decimal string rather than "50.0"; the reconciliation diff should compare like with like. A GTC child under a DAY parent is the genuinely unverified part and is marked.
- **Screens.** Labels and inputs are block and full width at the 390px viewport. Thesis, detail values, flash text, and the override reason all go through ERB escaping, including agent-supplied symbols in refusal messages. Guardrail detail sits in a right-aligned `dd` truncated at 160 characters, which reads cramped on a phone. The evaluation partial renders "(the  is the collar)" when the percent method is absent; say "percent floor" outright.
- **Approver guard.** Approvals and rejections carry `require_approver`, and `Submission::Submit` re-checks in the model. `reject!` has no model-level check. `new` and `create` are open to any signed-in user, while the plan says the second user reads.

## Step 4

- Sweep a shadow `submitting` row to `would_have_submitted`, not `submission_unknown`.
- Expiry is end of calendar day in New York. An evening proposal dies before the open.
- The tick expires with `find_each(&:expire!)`. One `IllegalTransition` from a race aborts the whole tick. Rescue per row.
- The sell payload ignores a working stop. Until the child action lands, the shadow instruction on the detail page should tell the operator to adjust the stop by hand.
