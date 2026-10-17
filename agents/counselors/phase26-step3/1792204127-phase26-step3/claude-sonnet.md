I found no look-ahead and no invariant break. The most serious problems are a late-bar edge case and two ways the features could stop being comparable later. I could only read files, because Bash is disabled here. I reviewed the working-tree copies of the staged files, not `git diff --cached`, and I ran no specs.

## Findings, most severe first

**1. `features.rb:74-78`: a partial bar can be treated as final.**
- `StopCollar::Candles.final` is correct about the calendar, but the cache in `Agent::MarketData.price_history` is not.
- A history fetched at 15:57 ET has a partial bar dated today. It stays "fresh" for 5 minutes (`HISTORY_FRESH`).
- A proposal at 16:01 ET passes `final` because `closes_at <= now`. The snapshot then freezes a partial close and volume as final, and every feature is skewed.
- Fix: in `final_candles`, drop the history if `history[:fetched_at]` is earlier than that day's `regular_closes_at` and the last candle is dated today. Marking all market features missing is acceptable.
- Simpler fix: take the last candle only if its date is before today, or if `fetched_at >= closes_at`.

**2. `features.rb:9` and `:7`: the version won't change when a formula does.**
- `VERSION = 1` is a bare constant. Edit the ATR window, the SMA input or the volume average, forget to bump it, and mixed formulas share version 1. They can't be separated when joined to outcomes.
- Fix: add a golden spec. It would feed a fixed candle series to `snapshot` and assert exact values together with `VERSION`. A formula edit then fails the spec until the value and the version are changed together.
- Also freeze the raw inputs: `close`, the ATR in dollars, and the bar counts used. Without them a changed formula can't be recomputed for old rows.

**3. `features.rb:26` and `proposals.rb:25`: two different "as of" dates.**
- The snapshot reads its own candles. `reference_close`/`reference_on` come from `Proposals.draft`'s `reference(instrument)`. I couldn't find `reference` by grep, so I haven't read it.
- If those two see different bars, such as a cache refresh between the calls, `bars_through` and `reference_on` disagree on the same row.
- Fix: record `reference_on` alongside `bars_through`, or have the snapshot refuse to proceed when they differ and mark the market features missing.

**4. `features.rb:39` and `:71`: rounding noise, and one bad divisor loses every feature.**
- `ratio(...)` rounds to 6 places, then `- 1` is applied. That yields values like `0.0500009999` instead of a clean rounding.
- Round once, after the subtraction.
- A zero close or average makes the BigDecimal division raise `ZeroDivisionError`. The outer rescue at line 28 then discards the features that did compute. This is unlikely but easy to prevent: guard `b.zero?` in `ratio` and mark that key missing.

**5. `features.rb:47-51`: `open_risk_ratio` has no context.**
- `Desk#open_risk` counts only protected positions (`desk.rb:111`). The record doesn't say how many positions were excluded, and `desk.excluded_by_reason` already has that.
- Two ratios taken under different protection states can't be compared later.
- Fix: also store `excluded_by_reason`, or the count of unprotected positions.

**6. Units and meanings aren't in the record.**
- The values are fractions (0.05 means 5%). `volume_vs_avg20` is a multiple whose average excludes the latest bar (line 42). The windows are plain SMAs, and ATR is a simple mean of true range rather than Wilder's.
- Today these live only in the code and the view helper. Add a `"units"` or `"defs"` hash to the jsonb, or at least comment them.

**7. `features.rb:70`: duplicate of existing code.**
- `atr` repeats `StopCollar::Candles#atr(n)` (`candles.rb:48`). Use `StopCollar::Candles.new(candles).atr(14)` instead.
- Check that it needs 15 bars: it takes `each_cons(2).last(n)`, which gives the same result when there are at least 15 bars.

**8. Low:** the instrument's last bar can be old with no staleness check, unlike `Candles.for`'s two-trading-day check. SMA, ATR and volume are then computed from that old bar. It is recorded in `bars_through`, so it can be filtered out later. `relative` already returns missing in that case.

## Checked and fine
- **Arithmetic.** ATR uses 15 bars for 14 true ranges. SMAs use exactly N bars including the latest close. The volume average uses the 20 bars before the latest, and the code asks for 21. Return63 uses `shared.last(64)`, which spans 63 sessions on dates both series share. SPY is aligned by date, and the last-bar equality guard is correct.
- **Missing data.** Each feature has its own `needs` guard, so none is estimated from fewer bars than it needs. The fake-client spec confirms the `59 final candles; 200 needed` case.
- **Never refuses or delays.** The snapshot runs before the lock at `create.rb:22` and the call to `Create` is not inside any lock. `Schwab::RateLimited` and `ServerError` both subclass `Schwab::Error`, which `final_candles` rescues, and the outer `rescue StandardError` covers everything else.
- **Rebalance path.** The planner calls `Create` under its lock, but only for `:rebalance`, so the Schwab fetch doesn't run there.
- **No Schwab call in render.** The partial and helper only read the jsonb.
- **Freeze trigger.** It is correct and covers `NEW = NULL` when `OLD` is non-null. Entries always get a non-null `features`, even on error, so they freeze at insert. `up` and `down` are symmetric, and `structure.sql` matches (line 60).
- **Cost.** The instrument's year of history is probably already cached by the draft, so the extra cost is one SPY fetch.
