**Verdict:** the shape is right and most rules read the PRD faithfully, but four things must change before commit: the evaluator writes durable state from a read-only tool, the collar's wide bound is always the percent floor, rule 1 is tautological, and the halt-extension logic lets a daily-loss trip erase a drawdown halt.

## Before commit

1. **The evaluator writes, and the hypothetical tool exposes it.** `Guardrails::DailyLossHalt` and `MaxDrawdownHalt` call `trip_rule_halt!`, which updates `system_settings` and writes an audit row. `EvaluateHypotheticalOrder` is `read_only: true`, `scheduled: true`, and says "Nothing is written", yet the unattended runtime can trip a halt through it. The spec only checks `OrderProposal.count`. Fix: rules return a `trip:` marker in the Result, `Report#halts` lists them, and `OrderProposal#evaluate!` applies the trip. The evaluator then returns; the writer writes.

2. **Halt extension is wrong** in `SystemSettings#trip_rule_halt!` line 16. A daily-loss trip during an indefinite drawdown halt has `rule_halt_resets_at` nil, so it "extends", relabels the halt as daily loss, and sets a reset at end of day. The drawdown halt is lost. Also, every entry evaluated during a drawdown halt re-trips with `resets_at: nil`, which always counts as extending, so each evaluation writes another `rule_halt_tripped` audit row. Do not re-trip when the same rule is already engaged, and treat nil as "later than any time".

3. **`wide` is always the floor.** The percent stop is in `candidates`, so `candidates.min <= percent` always and `[min, percent].max == percent`. The collar is `[tightest, percent]`, never `[tightest, widest candidate]` bounded by the floor as §5.4.1 says. When ATR and swing are both tighter than the percent, a stop between them and the floor passes inside. The `every method at or above entry` refuse can never fire for the same reason. Compute tight and wide over ATR and swing only, then apply the percent as the floor. The calculator spec's `wide >= floor` is trivially true; assert `wide` equals the ATR stop when it is tighter than the percent.

4. **Rule 1 cannot fail.** `MaxRiskPerTrade` compares `quantity × per-share risk` to the frozen `sizing["risk_budget"]`, which was computed from that quantity. Compare against the current fresh equity times the current rule percent, so the approve-time re-evaluation catches an equity drop as §0.4 requires.

5. **Unavailable is acknowledgeable for rules the plan calls hard fails.** §0.10 says rules 1 to 4, 7, and bad collar data are hard fails. Today a missing row for `max_positions`, `max_risk_per_trade`, `notional_cap`, or `stop_collar` is `unavailable`, as is stale equity in `MaxPositionExposure`. Add a hard-fail set alongside the `settled_cash` special case in `Guardrails::Evaluator`.

6. **`notional_today` omits `submission_unknown`.** An order that may be resting at Schwab does not count toward the day's cap. Add it.

7. **Exits cannot be evaluated by the tool.** A sell hypothetical has no quantity input, so `cost` is zero and `NotionalCap` fails with "no price to cap" every time. Accept `quantity` for sells, or default to the position's quantity.

## At step 3

- **Wash sale on sells warns on every stop-out inside 30 days.** The buys that created the lot being sold fall in the window, so a normal loss exit of a young position always warns. Per the tax rule, only replacement shares matter. Exclude the sold lot's own entry fills, or compare window-buy quantity to sell quantity. Also scope the buy-side loss lookup to `Account.taxable`; `context.account` is only the taxable account by accident. Note that partial-exit losses on open trades never count anywhere, since `realized_pnl` is set only at close.
- **Settled cash triple-counts a submitted buy** once the sync ingests its order: the proposal, its own working order, and whatever Schwab nets. Exclude orders with `order_proposal_id` from `live_broker_buys`. A MARKET broker buy counts as zero.
- **Positions and exposure ignore pending entries.** Two validated proposals on new symbols both pass at one under the cap. Count unfilled entry proposals on unheld instruments.
- **Exits are judged on almost nothing:** halt, lock, wash sale, notional. Nothing checks the instrument is held or the quantity fits. Add with the child action.
- **Drawdown reads yesterday's snapshot**, never today's equity. A ten-percent day trips nothing until tonight. Fold in `Desk#day_change` or accept and document.
- `Sizing` uses equity without the staleness check, so the tool reports a quantity from a stale balance. `Rule#param` raises `KeyError` on malformed params instead of returning unavailable.

## Fine as is

Scale-in passes `max_positions`; ATR, swing buffer, chandelier, and percent formulas match §5.4.1; the stale-history path refuses because `price_history` only serves a stale entry marked `stale: true` on Schwab failure, and the quote gate refuses on a cached quote older than two minutes; the daily-loss reset at end of day New York with the tick's sweep is consistent, though the class comment says "tomorrow's open"; `pending_reconciliation` and the kill switch are right; seeds are idempotent and run in production before the development-only return.
