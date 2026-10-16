`RateLimited` is a `Schwab::Error`, so that rescue is fine. Report follows.

## Review: Phase 2.5 step 1

I read the code and specs only. I ran nothing, so each finding below comes from reading the code.

The invariants that hold:
- **Trade/book split:** `Guardrails::Evaluator` iterates `TRADE_TYPES` only (`evaluator.rb:12-14`), and `scope` is derived from `rule_type` (`risk_rule.rb:20`).
- **Policy superseding:** the lock order is row lock, then settings lock, then `update!(active: false)`, then the successor (`superseding.rb:21-33`). That gives one audit row and one active row, and the halt lock requires an override reason.
- **No Schwab call from a page:** only the job and `Book` call `Agent::MarketData`; the pages read stored rows.
- **Approver-only writes:** every write controller has `require_approver`.
- **No proposal in step 1:** nothing creates one.
- **Fractions:** weights, bands and drift are fractions of equity throughout.

### Defects

**1. Partial positions sync passes as fresh** — `book.rb:45`
- `account.last_sync(:positions)` uses `advanced_cursor`, which counts `partial` runs (`sync_run.rb:17`). A partial sync after the close therefore clears the "positions not synced since the close" check.
- Weights are then computed from positions that may not have been refreshed.
- Fix: require a `succeeded` run with `finished_at >= closed_at`.
- Also check `position.synced_at >= closed_at` for every position that feeds a weight. `Desk` already relies on that column.

**2. Zero price crashes the job** — `book.rb:55, 81, 104`
- `position.last_price.blank?` is false for `0`, because `BigDecimal(0).blank?` is false.
- `.compact` on the quote hash (line 81) keeps a `0`.
- Line 104 then does `notional.abs / close`, which raises `ZeroDivisionError`. The whole run dies instead of writing "unavailable".
- Fix: use `price.blank? || !price.positive?` at line 55, and `.select { |_, v| v&.positive? }` at line 81.

**3. A malformed or non-positive band crashes the job and the preview page**
- `required_params_present` (`risk_rule.rb:60-63`) checks presence only. `"abc"`, `"0"` and `"-5"` all supersede successfully.
- `BigDecimal("abc")` then raises `ArgumentError` at `book.rb:88` and `band_preview.rb:21`, which means a nightly crash and a 500 on the preview page.
- Blanking the percent field in the preview form is dropped by `compact_blank` (`risk_rules_controller.rb:35`). `candidate.param(:percent)` then raises `KeyError`, also a 500.
- Fix: validate numeric type and sign per rule type. For `rebalance_band`, require a number in (0, 100]. Have `BandPreview` rescue `KeyError` and `ArgumentError` and render "enter a percent".

**4. Target edits can write over a concurrent change** — `target.rb:26-27, 38-45`
- `reweigh!` and `retire!` evaluate `before: audit_state` before the lock, and the record was loaded by the controller before the lock.
- The advisory lock keeps the 100% sum safe. But a concurrent reweigh or retire makes the `before` in the audit row stale.
- A reweigh on a target that was just retired runs with in-memory `active == true`, so it validates against the active set and writes a weight onto a retired row.
- Fix: inside `change!`, after `lock_set!`, call `reload` (or `lock!`) and compute `before` there. Make `reweigh!` raise `StaleObjectError` or `RecordNotFound` if the row is no longer active.

**5. Edit and retire controllers crash or 404 on races**
- `allocation_targets_controller.rb:23` and `retirements_controller.rb:6`: `Target.active.find` raises `RecordNotFound` on a double-click or a retire in another tab. The user gets a bare 404.
- `deployment_policies_controller.rb:7`: a stale form id gives `RecordNotFound`, not the "refused" flash the comment promises.
- `StaleObjectError` raised from `supersede_with!` is not rescued in this controller or in `RiskRulesController`.
- `classifications_controller.rb:6`: two concurrent saves hit the unique index and raise `RecordNotUnique`, which is not rescued.
- Fix: rescue these and redirect with an alert.

**6. Drift pages show old rows as current** — `drift.rb:13`; `_allocation.html.erb:8`; `desk.rb:116`
- `current` takes the global `max(as_of)` and renders it with only a date.
- If the nightly job fails or is skipped for days, the dashboard keeps showing the last good night with no staleness flag.
- Fix: compare `as_of` to the latest trading day (`MarketDay`) and render a warning when it is behind.
- Separately, a target added after the last run is silently omitted from the dashboard list. It shows only on the targets screen.

**7. A rerun overwrites a good row with "unavailable"** — `drift_job.rb:25-27`
- A later same-day rerun that fails (for example, quotes down) replaces the day's valid measurements with `unavailable`.
- Fix: do not downgrade an existing available row, or keep the prior values in `detail`.

**8. Backfill and fallback-calendar gaps** — `book.rb:40-45`; `drift_job.rb:8`
- `perform(date)` for a past date validates against that day's close, but the balance and positions are the latest ones. The row is labelled for `date` while carrying today's weights.
- Fix: require `date == MarketDay.today`, or refuse past dates.
- `regular_closes_at` can be nil, and `balance.as_of >= nil` raises (`book.rb:40, 43`). `MarketDay.for` can return a fallback row. `Snapshot` and `TickJob` both require `day.schwab?`; the job does not.
- Fix: guard the nil close, and check `day.schwab?` or mark the rows unavailable.

**9. Band comparison disagrees between job and preview** — `book.rb:105`; `band_preview.rb:16`
- The job compares the unrounded drift to the unrounded band. The preview compares the stored 6-decimal drift to a band built from the rounded `one_share`.
- At the boundary, the preview's "before" (the stored action) and "after" can disagree for an unchanged band.
- Fix: compare the rounded values in both places. Alternatively, store the unrounded one-share.
- Also, `before` shows `proposed` and similar actions as if they were the band's verdict. Restrict the diff to `none` and `reported` rows.

**10. Smaller items**
- `risk_rules` has no DB check that `scope` agrees with `rule_type`, and no check on the `scope` values. Only the model enforces it.
- `deployment_policies` `weeks` has no upper bound. A huge value raises `ActiveModel::RangeError`, a 500.
- `rebalance_phrase` (`allocation_helper.rb:28`) calls `drift.notional.positive?` and crashes on a `reported` row with a nil notional. The job never writes one, but nothing stops it.
- `Allocation::Target.add!` uses `find_by(symbol:)`. Symbols can be reused through `symbol_history`, so this can pick an arbitrary instrument.
- After a rolled-back `supersede_with!`, the in-memory `self.active` is still `false`. This is harmless in the controller, but the spec only passes because `current` reloads.

### Spec gaps and specs that do not test what they name

- **Concurrency:** `target_spec.rb` has no concurrent-edit test. The 100%-cap spec is single-threaded, so it would pass with no advisory lock at all. Add two threads, each with its own connection, adding 60% targets, and expect exactly one to succeed. Do the same for two simultaneous `supersede!` calls on one policy or rule, expecting one `StaleObjectError`.
- **Fresh-data gates:** `drift_job_spec.rb:55-77` covers the post-close positions check, one unpriced position, and a quote failure. It does not cover:
  - a balance older than the close;
  - a `partial` positions sync (defect 1);
  - a delisted covered instrument;
  - a zero price (defect 2);
  - a non-positive equity;
  - a missing band rule;
  - a stale quote.
- **Page renders:** nothing asserts that a render makes no Schwab call. Stub the client to fail and render the dashboard and targets pages.
- **Malformed rule params:** there is no spec for an invalid or blank band, for the preview endpoint or for `supersede!`. That is defect 3.
- **Audit rollback:** the `classify!` spec says the refused tag "rolled the class change back too" but never asserts the audit rows rolled back. Add `expect(AuditEvent.where(kind: "instrument_classified").count).to eq(1)`.
- **Setup-scoped book rules:** `risk_rule_spec.rb` tests the one-active index with a null setup only. A setup-specific duplicate is untested.
- **Band boundary:** `drift_job_spec.rb:47-53` covers the one-share floor. Nothing covers drift exactly equal to the band, or the class target's band being the rule band alone.
- **Authorization:** `allocation_spec.rb:48-51` covers a non-approver on create and classify. The `update`, `retirement`, `deployment_policy` and `preview` endpoints have no non-approver test.
- **Stale policy form:** a submit against a superseded `deployment_policy[id]` is untested. It would expose defect 5.
- **Halt override:** the controller path (flash, the `override_reason` field) is untested for `DeploymentPoliciesController` and `RiskRulesController`.
- **Rerun:** a rerun that does not overwrite a proposed row is covered. A rerun downgrading a good row (defect 7) is not.
