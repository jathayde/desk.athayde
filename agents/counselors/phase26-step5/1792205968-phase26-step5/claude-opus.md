# Review: Phase 2.6 step 5 (decay check and costs)

I only read code for this review. Nothing was edited or run, so I haven't confirmed whether the specs cover the scenarios below. Findings are most severe first. "Plan" means `docs/phase-2.6-plan.md`.

## 1. Cost arithmetic: `app/models/trade/costs.rb`

**1a. Severe: a stop-out is measured against the planned stop, not the stop that actually triggered (`costs.rb:46-51`).**
- **Scenario:** entry 50, planned stop 47, initial risk $3 a share. The operator trails the stop to 52 and it fills at 51.90. `stopped_out` is true, so the cost is (47 − 51.90) per share, which is −1.63R. Realized R is +0.63, but gross R comes out at about −1.00, and it's tagged `comparable`. A winning trade reports a gross R far below its net, and that drags `Setup#gross_avg_r` down with it.
- **Fix:** `orders.stop_price` exists. Measure against `@ledger.closing_leg.activity.order.stop_price`, adjusted for any split. If you want to keep the plan's "planned stop" wording, tag the leg `not_comparable` whenever that price differs from `planned_stop`.

**1b. High: only the last exit leg is measured (`costs.rb:47-50`).**
- **Scenario:** a stop for 100 shares fills as 60 at 46.80 and 40 at 46.50. The cost uses only the 40-share leg at 46.50, so both the quantity and the price are wrong.
- **Fix:** add up the exit legs that share the closing leg's `activity.broker_order_id`, weighted the same way `entry_cost` weights the fills. This mirrors `Ledger#initial_entry_legs` (`trade.rb:215-220`).

**1c. High: an entry tagged `comparable` can still be measuring the market's drift (`costs.rb:53-57`).** Filling on the same calendar date as the approval isn't enough.
- **Scenario A:** the operator approves at 08:00. Step 1 records that quote as `stale` (prior-close mark, or a pre-market spread). The order fills at the 09:30 open, so the overnight gap is booked as cost.
- **Scenario B:** a limit set below the market is approved at 10:00 and fills at 15:00 after a dip. The fill is below the mid, so the "cost" is negative and gross R ends up *below* realized R.
- **Fix:** tag `not_comparable` when `quote["stale"]` is set. Also require the limit to have been marketable at approval (`limit_price >= ask`). Only then is fill minus mid the actual spread paid.

**1d. Medium: trades with no proposal still get a stop cost tagged `comparable` (`costs.rb:50`).** `proposal&.shadow?` is nil when there's no proposal, so the tag defaults to `comparable`. Plan §0.8 says "Nil when there is no proposal." Legacy and manual trades reviewed with a stop therefore get a `gross_r` and are counted in `cost_sample_size`.
- **Fix:** add `return nil unless proposal` to `stop_cost`.

**1e. Low:** when an approval has no `quote_at_approval` (anything approved before step 1), the trade gets no entry key at all rather than `unavailable`. That's acceptable, but the trade page then shows nothing about the entry.

**What's fine here:**
- The entry sign (fill − mid > 0 means money lost) and the weighted average fill across partial fills.
- The unit conversion in `stop_cost`: the ratio cancels, so the dollars are (planned − fill) × quantity, with R in original-entry units consistent with `initial_risk`.
- No double counting. `leg.price` is the trade price and realized P&L comes from `net_amount` (`linker.rb:72-73`). Gross R adds back only fill slippage, and commissions and fees stay netted. The trade page should say "gross of slippage, still net of fees".
- The `mid_of` guards.

## 2. Gross figures: `app/models/setup.rb:29-38`

**Medium: the two averages cover different trades, so their difference isn't the cost.** `avg_r` is over every eligible trade, while `gross_avg_r` covers only the trades with a measured cost. Plan §0.8 says "the difference is the cost", but subtracting these two gives selection bias plus cost.
- **Scenario:** the 7 costed trades are same-session fills in calm markets and the other 5 gapped. The gap between the averages then says nothing about cost.
- **Fix:** also store the realized average over the same `gross_r IS NOT NULL` trades, and show that next to the gross average.
- **Related:** `gross_r` exists when only the stop was comparable (the entry was `not_comparable`), so "N with measured costs" mixes fully and partly measured trades. Require a comparable entry before a trade gets a `gross_r`.

## 3. Decay check: `app/models/decay_check.rb`, `hypothesis.rb:72`

**3a. Medium: the "once per new close" test keys on the latest `closed_at` (`decay_check.rb:15-16`).** A new trade may not carry a newer timestamp than the last row saw.
- **Scenario:** a fill syncs late with an older `executed_at`. Or a trade earlier in proposal order closes before the latest close. Or a trade gains or loses its R on recompute. In each case the set of trades changes, but no row is written.
- **Fix:** the row already stores `trade_ids`. Make a row due when `trades.map(&:id).sort != last.trade_ids.sort`. That's exact and simpler.

**3b. Medium (invariant): `since_sample` recounts the sample instead of reading the frozen one (`hypothesis.rb:72`).** It is `evidence_trades.drop(min_sample)` over live rows, while the verdict froze its trade ids in `evidence["r"]`.
- **Scenario:** a trade appears later whose proposal sorts before the sample's last proposal. For example, a cancelled or expired named proposal whose fill syncs late, then gets adopted by `Journal::Linker#adopt_proposal`. `ready?` only guards `occupying` proposals. The offset then shifts, a frozen sample trade leaks into the decay set, and a later trade drops out.
- **Fix:** `evidence_trades.reject { evidence["r"].key?(it.id.to_s) }`, further limited to proposals created after the sample's last proposal. Even if the linker can't actually do this today, tying decay to the frozen ids is the honest expression.
- **What's fine:** naming an accepted hypothesis can't change the verdict itself. `verdict` returns the frozen `evidence` once decided, and the trigger freezes it.

**3c. Medium (interpretation): repeated looks.** The interval is two-sided 95%, so each look flags at 2.5%. It's recomputed on a growing sample at every new close. Over 50 closes, the chance of at least one false flag under "no decay" is far above 2.5%, and it keeps rising. This comes from the plan, not the code. But the class comment ("does not raise alarms by repetition alone") claims more than the rule delivers.
- **Fix:** either fix the wording ("re-examined at each close; a flag is a prompt to look, not a test") or look on a fixed schedule (n = 20, 40, 80, …) with the level split across the looks.
- **Also:** a cumulative mean is slow to show real decay. A rolling window of the last 20 would answer "is it decaying" better than "since the sample".

**3d. Low: the flag says the wrong thing in one common case.** It fires when the upper bound is below `expected_mean_r`, the number declared before any evidence. A hypothesis that cleared at a mean of 0.25 against a declared 0.50 can be flagged on its first check without anything decaying. The suggestion text ("running below what was accepted") misstates this: change it to "below what was declared".

**3e. Low:**
- `decay_check.rb:20`: the flag compares the unrounded `high` against `expected.to_f`, while the stored and displayed values are rounded. Step 4 settled on comparing stored rounded values; do the same here.
- The bootstrap is unclustered while calibration clusters by week. That's a consistency note, not a bug.
- The percentile bootstrap undercovers on skewed R at n = 20, which adds to the false flags in 3c.
- §0.7 says "20 trades since acceptance", but the code counts since the sample, which includes trades named during testing after the sample filled. Those are still out of sample, so this is defensible, but record it in §8.

**What's fine here:** the 20-trade floor is applied after the closed-with-R filter. Trades are read in proposal order. The job isolates each hypothesis's failure. Nothing touches a rule or a setup.

## 4. Invariant breaks

- **Audit row outside the transaction (`decay_check.rb:21-25`).** `create!` and `AuditEvent.log` aren't wrapped together. If the log raises, a row is left with no audit. Step 1 settled that a result and its audit row are written in one transaction, so wrap both.
- **Retired hypotheses keep showing as decaying (`research/digest.rb:17-18`).** `decay_checks` isn't filtered by status, so the Sunday email keeps listing "Decaying: #n" for a hypothesis retired after its flag. Filter with `joins(:hypothesis).merge(Hypothesis.status_accepted)`. `/research` already limits it to accepted hypotheses (`_hypotheses.html.erb:13`).
- **Same-day rerun (`decay_check.rb`, plus the unique index on `(hypothesis_id, as_of)`).** If a trade closes between two runs on the same Saturday, the second `create!` raises `RecordNotUnique`. The job reports it and moves on, so nothing breaks, but it's noise. Return nil when a row already exists for `as_of`.
- **Computed on render:** `decay_summary`'s "N of 20 since the sample" (`research_helper.rb:79`) loads the evidence trades for each accepted hypothesis. It's cheap and consistent with `hypothesis_progress`, so it's acceptable. `expected_r` is arithmetic on stored fields, which the plan allows.
- **Nothing found** where a check changes a rule, a setup, or sizing.

## 5. Simpler options that do the same

- Group the stop legs by broker order id, reusing `Ledger#initial_entry_legs` (1b).
- Decide when a check is due by comparing `trade_ids` sets (3a).
- Build `since_sample` from the frozen `evidence["r"]` ids (3b).

Taken together, these are less code than what's staged now.
