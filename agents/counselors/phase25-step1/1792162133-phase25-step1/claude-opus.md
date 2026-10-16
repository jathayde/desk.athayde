I reviewed step 1 and found two invariant breaks and several crash or data-integrity defects. Another session was editing these files while I read them; my line numbers match the state after `Allocation::Target.add!(symbol:, target_percent:)` and `Allocation::Drift.current` landed. The evaluator split, the policy supersede path, page renders not calling Schwab, approver-only writes and audit coverage all hold.

## Invariant breaks

**1. A partial or pre-close positions sync counts as fresh** — `app/models/allocation/book.rb:45`
- `account.last_sync(:positions)` is `advanced_cursor.maximum(:finished_at)`, and `advanced_cursor` includes `partial` (`sync_run.rb:17`).
- On a partial run, `positions_job.rb:30-31` keeps yesterday's rows for positions it couldn't map and skips the unresolved ones. It still writes a fresh balance (`:32`). The Book then computes weights from a mix of old and new rows and treats them as fresh.
- Keying on `finished_at` also accepts a run that started at 15:58 and finished at 16:01, which read pre-close data. The tick job already tests post-close with `started_at` (`tick_job.rb:39`).
- **Fix:** require that the latest positions run since the close succeeded, keyed on `started_at`: `SyncRun.for(:positions, account).where(started_at: closed_at..).order(:started_at).last&.succeeded?`. Otherwise add "positions sync partial" or "positions not synced since the close".

**2. Rerunning the job for a past date passes the freshness check with today's numbers** — `drift_job.rb:8-12`, `book.rb:43,45`
- `perform(date)` accepts any trading day. A balance or sync from a later day still "postdates that day's close", and unheld prices come from live quotes. A manual rerun for Oct 14 on Oct 16 would write Oct 16 weights labelled as the Oct 14 close.
- **Fix:** also bound the inputs above, before the next session opens (or simply refuse `date != MarketDay.today`). `Snapshot.balance_for` (`snapshot.rb:35`) already bounds its window like this.

## Crashes and stale data

**3. A zero price crashes the whole run** — `book.rb:55`, `book.rb:81`, `book.rb:104`
- `last_price.blank?` lets `0` through, and a quote `last` of 0 survives `.compact`.
- `notional.abs / close` then raises `ZeroDivisionError`, so the run writes no rows at all instead of marking itself unavailable.
- **Fix:** test `positive?` at both places and add "XYZ priced at zero" as a reason. That matches how `Instrument#priced_again?` treats zero.

**4. A non-numeric band percent crashes the nightly job and the preview** — `risk_rule.rb:56`, `book.rb:88`, `band_preview.rb:21`
- `required_params_present` only checks that `percent` is present, so a supersede with `"five"` or `"-5"` saves.
- The nightly job then raises in `BigDecimal(band_rule.param(:percent).to_s)`. No rows are written, and the dashboard keeps showing the previous day's rows as current.
- The preview returns a 500 for a blank percent (`compact_blank` drops the key, then `param` raises `KeyError`) or for `"five"` (`ArgumentError`). `risk_rules_controller.rb:26-35` rescues neither.
- **Fix:** validate book params as positive numbers in `RiskRule`. In the preview, redirect with an alert unless `candidate.valid?`. In `Book#stale_inputs`, add "rebalance_band percent unreadable" as a reason rather than raising.

**5. A tiny weight gives a 500 instead of a refusal** — `target.rb:31`
- `"0.00001"` becomes 1e-7, which passes `greater_than: 0`. The `scale: 6` column rounds it to 0, and the database check `target_weight > 0` then raises `ActiveRecord::StatementInvalid`.
- **Fix:** round in the setter (`.round(6)`) so validation sees the value that will be stored.

## Races and audit accuracy

**6. A reweigh or retire uses the in-memory row from before the lock** — `target.rb:38`
- `before: audit_state` is evaluated before `lock_set!`.
- If two reweighs race, the second audit row's `before` shows the original weight, not the first edit's.
- If a reweigh races a retire, `update!(target_weight:)` writes a new weight onto the now-retired row and logs `active: true` before and after. The 100% sum stays correct.
- **Fix:** inside `change!`, after `lock_set!`, call `reload`, refuse if `!active?`, then capture `before`. `add!` passes `before: nil`, so it should skip the reload.

**7. The job can run on a weekday holiday** — `drift_job.rb:10`
- It checks `day.trading?` only. If the Schwab hours fetch failed, the fallback day (`market_day.rb:38`) counts every weekday as trading, so rows can be written for a holiday.
- `Snapshot` guards with `day.schwab? && day.trading?` (`snapshot.rb:14`). Match it.

## Specs that don't test what they name, and gaps

- **`allocation_spec.rb:55`, "never recomputing them":** it only checks page text. Change the position's `market_value` after creating the drift row and assert the page still shows 21.2%, or assert zero quote calls to the fake client.
- **Concurrent target edits:** none, though the invariant names them. A two-connection spec (A holds `lock_set!` in an open transaction at 60%, B's `add!` at 50% blocks and is refused) needs transactional fixtures off for that example. The same applies to two concurrent policy supersedes, which should mint exactly one v2.
- **`drift_job_spec.rb:55-77` misses these unavailable cases:**
  - a partial positions run
  - a run that started before the close and finished after it
  - a stale balance
  - a delisted instrument a target covers
  - a missing `rebalance_band` rule
  - zero price, unreadable band, and a past-date rerun (after fixes 3, 4 and 2)
  - that one `allocation_drift_recorded` row exists per unavailable line
- **Class exclusion:** untested. No spec has an instrument with its own target that also belongs to a class with a class target (`book.rb:65`).
- **`deployment_policy_spec.rb:17-18`:** it checks the override note but not the audit row's `during_halt: true` and `override_reason`. `risk_rule_spec` doesn't check them either.

## Lower priority

- **Wrong-row symbol lookup** — `target.rb:17`: `Instrument.find_by(symbol:)` picks an arbitrary row when a symbol is shared, for example a delisted predecessor and its replacement. A target on the delisted row makes every run unavailable ("XYZ delisted"). `Proposals.draft` (`proposals.rb:9`) has the same weakness. Preferring `where(delisted_at: nil)` in both would close it.
- **Concurrent classify** — `instrument.rb:52-53`: two concurrent saves adding the same tag raise `RecordNotUnique`, which `ClassificationsController` doesn't rescue, so the user gets a 500.
