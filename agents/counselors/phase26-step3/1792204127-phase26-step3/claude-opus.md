# Review: Phase 2.6 step 3 (decision snapshots)

I only read files for this review, nothing that writes. Findings are listed most severe first. Fixing #1 and #2 matters before commit; #3 to #5 are needed for the features to be usable when joined to outcomes later.

## 1. A partial bar can be read as final, through the cache's age
**Where:** `app/models/research/features.rb:77`, using `app/models/stop_collar/candles.rb:36-40`

`final_candles` passes `now: Time.current` to `Candles.final`. But the candles can come from the cache, which `Agent::MarketData.price_history` treats as fresh for up to 5 minutes (`HISTORY_FRESH`, `market_data.rb:38`). `final` admits today's candle once `regular_closes_at <= now`, but it never asks when the candles were fetched.

**Failure:** At 15:58 ET the agent calls `price_history` on XYZ, which caches today's bar as it stood at 15:58. At 16:02 it proposes an entry. The draft and the snapshot both get the 15:58 cache entry back, and today's candle passes as final. The result:
- `volume_vs_avg20` is badly understated (it's missing the last minutes and the closing auction).
- The SMAs, the ATR and the 63-session return use the 15:58 price instead of the close.
- `bars_through` reads today, so the row looks as if it was built from a true final bar. Nothing joined later can tell it apart.

**Not only this step:** step 1's `Proposals.reference` (`proposals.rb:41`, `Candles.for(...).final` with the default `now`) has the same flaw. So `reference_close` and `reference_volatility` (and with them every forecast's levels and baseline) can be built from that partial bar.

**Fix:** in `final_candles`, pass `now: history[:fetched_at]`. The entry already carries `fetched_at`. Fix it the same way inside `Candles.for`/`#final` so both callers are covered. Even a fetch made just after 16:00 can return a daily bar Schwab hasn't settled yet. A margin of about 15 minutes after `regular_closes_at` before today's bar counts as final would also cover that case.

## 2. The trigger lets `features` be written later, after the fact
**Where:** `db/migrate/20261017120001_add_proposal_features.rb:16`

`OLD.features IS NOT NULL AND …` only freezes the column once it is set. Going from NULL to a value is allowed at any time.

**Failure:** someone backfills snapshots onto proposals from before this step, or onto an exit. The new values are computed from bars that came after the decision, yet they sit in a column the page describes as "frozen when proposed." That breaks "nothing a decision rests on is editable after the fact" (plan §0 invariant). `reference_close` has the same pattern, but the case is stronger here: `Proposals::Create` always sets `features` on an entry before `save!`, and the error path returns a hash too, never nil. So the column can be made insert-only without breaking anything.

**Fix:** add `OR (OLD.features IS NULL AND NEW.features IS NOT NULL)`, and add a spec next to the existing `update_columns` one (`features_spec.rb:20`) that sets features on an exit and expects a refusal.

## 3. One failing step throws away the whole snapshot
**Where:** `features.rb:28-30`

The `rescue StandardError` wraps everything, including `open_risk`, which runs last and reads `Desk` (positions, balance, token status).

**Failure:**
- An exception inside `Desk#rows`, for example from a position with odd data, discards market features that were already computed correctly. The row becomes `missing.all`.
- The same happens for a single bad candle: a zero or nil `close` raises `ZeroDivisionError` or `NoMethodError` in `ratio`.

Smaller point: `proposal.id` is nil at this point, because the snapshot runs before `save!`. So the error context `{ features: nil }` can't be traced back to anything.

**Fix:** catch errors in each section (market, relative, open risk) and record the reason under that section's own keys. Keep the outer rescue only as a last resort. Use `proposal.instrument.symbol` as the error context.

## 4. Things that will hurt the join to outcomes later
- **Units are inconsistent.** `close_vs_sma*` is a difference (0 means at the average), but `volume_vs_avg20` is a multiple (1 means at the average). The names don't show this. The view hides it (`research_helper.rb:40-42`), but anyone reading the jsonb won't see the view. Make both the same kind of number (e.g. `volume_vs_avg20 - 1`), or put the unit in the key (`volume_multiple_avg20`).
- **The window convention differs too.** The SMAs include the last close (`:39`), while the volume average excludes the last bar (`:42`). Both choices are defensible, but nothing records them. Say so in the module comment.
- **`VERSION = 1` isn't checked by anything.** The ATR, SMA and volume formulas have no test of exact values, only a range check (`features_spec.rb:19`). Add a spec that runs the market features on fixed synthetic candles and checks exact values, as test 3 already does for the relative return. Then a formula change fails CI until someone looks at the version.
- **`open_risk_ratio` doesn't say what it leaves out.** `Desk#open_risk` counts only `:protected` positions (`desk.rb:111`), and the balance is whatever was last synced. A desk holding positions with no stop shows a low ratio. Store `desk.excluded_by_reason` and the date of the balance the ratio was read from next to it.
- **The benchmark key is hard-coded.** The key `return63_less_spy` names SPY, but the code reads `Correlation::BENCHMARK`. Either fix both to SPY or store the benchmark symbol in the snapshot.
- **Rounding happens too early.** `ratio(...) - 1` (`:39`) and the difference in `relative` (`:63`) round each ratio before subtracting. Round once, at the end.

## 5. It skips the plan's freshness check
**Where:** `features.rb:74-81`, against plan §0.4

The plan says to read through `StopCollar::Candles.for`, which refuses a latest candle more than 2 trading days old. `final_candles` repeats the stale-cache check but drops the age check. A halted name whose last bar is three weeks old still gets SMA, ATR and volume values; only `return63_less_spy` reports a problem, because SPY's last date differs. `bars_through` records the date, so the problem can be spotted later. Still, the values look valid when they aren't.

**Fix:** mark the market features missing when `bars_through` is older than `StopCollar::Candles.oldest_acceptable_date`.

## 6. Simpler versions
- **One read of the history.** The draft has just read the same history for `reference_close`, and `features.rb` fetches it again. If the 5-minute cache expires between the two reads, `bars_through` can differ from `reference_on`. Sharing one read, or one helper that both use, removes that gap and the duplicate fetch code.
- **Reuse the existing ATR.** `features.rb:70` duplicates `StopCollar::Candles#atr` (`candles.rb:48`), and the results are the same. Use `StopCollar::Candles.new(candles).atr(ATR_DAYS)` so the snapshot and the collar can't drift apart.
- **Optional:** run the "already waiting" and "unresolved" refusals as cheap checks before the snapshot. That avoids spending two history calls on a proposal that will be refused anyway. They're checked again under the lock, so nothing is lost.

## Fine as it is
- **Arithmetic:**
  - ATR needs 15 bars, giving 14 true ranges divided by 14.
  - Each SMA requires its full window of N bars.
  - Volume compares the last bar with the 20 before it.
  - The relative return needs both series to end on the same date. It then joins on shared dates and needs 64 shared closes, which gives 63 intervals.
  - A one-year range gives about 250 final bars, so the 200-day average is supported.
- **Invariants:**
  - The snapshot can't refuse, delay or change a proposal; it only sets `features`.
  - It runs before the lock and the transaction. Rebalance buys don't take it, so the planner's locked path makes no Schwab call.
  - Rate limits are a subclass of `Schwab::Error` and are caught (`:79`).
  - The page renders only the stored jsonb (`show.html.erb:13`), and only when it is present.
- **Migration:** the down migration restores the previous trigger message. The `format` with `%s` is safe, and the spec shows `update_columns` is refused once the column is set.
