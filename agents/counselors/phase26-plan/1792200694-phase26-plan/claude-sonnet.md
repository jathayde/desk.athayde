# Phase 2.6 plan review

I read the draft, the gap analysis, PRD §6, the Phase 2 and 2.5 conventions and the listed code. I did not read `AgentRun`, `Agent::Tools`, the `MarketDay` model or `Agent::Conversation`'s internals beyond a grep, so findings that touch them are marked "check". Nothing was edited or run.

## 1. Statistical defects

**1.1 Resolution rule: path vs fill (§0.1).**
- The forecast is scored on the price path from the next session whether or not the limit ever fills. The probability the agent states will be conditional on the trade being live, but the score is unconditional.
- A limit buy below the market whose price path hits the target before ever touching the limit scores `hit` for a trade that never existed.
- Rewrite the first sentence of §0.1 as: "From the first session on or after `starts_on` whose low reaches `entry_price` (the entry window is `entry_window_days`, default 5 sessions), within `horizon_days` sessions counted from that session, the daily high reaches `target_price` before the daily low reaches `stop_price`."
- A forecast that never enters is `void` with reason `never_entered`. It is reported as a rate beside every calibration cell, not hidden.
- Daily bars cannot order the entry against the levels within the entry day. On the entry day only the stop is tested (low ≤ stop → stop, flagged `ambiguous`). The target counts from the next session.
- At creation, store `reference_close` and its bar date. Refuse a forecast unless `stop < reference_close < target`, or the claim can be trivially true or false on day one.
- Add a §7 line: the forecast is conditional on entry, which is what the agent actually estimates. The cost is that unfilled orders drop out, and the rate of that is shown.

**1.2 Next-session start (§0.1, §0.2).**
- Starting at the next session is the right look-ahead choice: a same-day daily candle includes range from before `made_at`.
- Say so, and say that a session of path is deliberately unscored.
- Entries expire at end of day (`Proposals.draft`), so a real fill happens on day D while the forecast window opens D+1. Document the mismatch, or let the entry-touch rule above own it.

**1.3 Horizon in trading days (§0.2).**
- "The trading day `horizon_days` after it" is off by one: it makes a window of horizon+1 sessions.
- It also relies on a Schwab calendar for future dates, and `MarketDay` may not hold rows that far ahead.
- Replace with: "The window is the first `horizon_days` daily candles on or after the window opening. A forecast resolves `expired` only when that many candles exist, none touched a level. `resolves_on` is an estimate for display, not a stored fact."
- This removes the calendar dependency and handles holidays and early closes.

**1.4 Ambiguous days (§0.1).**
- Counting a both-touched day as the stop biases the hit rate down, most on wide-range days and tight ATR-based levels. Reliability will then read as overconfidence that is an artifact of the rule.
- Keep stop-wins as the headline, but also report the ambiguous count and the Brier score with ambiguous days excluded. Best/worst-case bounds are cheaper to explain.
- If more than 10% of resolved forecasts are ambiguous, the headline says so.

**1.5 Partial candles and stale data in the resolver (§2).**
- The resolver must not resolve on today's bar. Only bars dated before today, or today's bar after the close plus the run time, count.
- It must refuse `history[:stale]` (`Agent::MarketData.price_history` serves cached data for 12 hours on a Schwab failure). It may never infer `expired` from the absence of a candle.
- Add: "A forecast resolves `expired` only when a candle dated on or after the window's last session is present. A rate limit or Schwab failure leaves it unresolved."
- Make the rule a pure function, `Forecasts::Resolution.call(forecast, candles)`, tested against fixtures: gap-through, equal touch, ambiguous, split, short history, entry-day.

**1.6 Splits (§0.2, §5).**
- A level frozen in pre-split dollars, scored against adjusted or unadjusted candles, mis-resolves either way.
- Don't wait for verify item 65. Store `reference_close` and its bar date at creation. At resolution, compare the candle for that date with it.
- A ratio off by more than 2% means a split or adjustment has happened. Void with reason `split` rather than rescaling silently.
- The 35% one-day-move guard from 2.5 step 5 applies as well.

**1.7 Survivorship of void (§0.1).**
- Delisted, acquired or bankrupt names disproportionately lose. Excluding them as `void` biases the hit rate up.
- Void reasons must be an enumerated column: `never_entered`, `split`, `no_history_at_start`, `data_unavailable`.
- Candles that stop before the window ends (delisting, CUSIP succession with no successor candles) resolve `miss`, `detail.ended_early`, unless the last close is at or above target.
- Use `Instrument#predecessor_instrument` to follow succession first.
- `void` is allowed only after N failed nights (say 5). One bad night is not void.
- Calibration cells show the void count and rate.

**1.8 Brier baseline (§0.3).**
- The in-sample base rate is p̄(1−p̄), the best possible constant, and it ignores that forecasts have different target/stop geometries. A pooled base rate across 1:1 and 3:1 setups means little.
- Keep it, but add a geometry baseline that needs no fitting: the driftless gambler's-ruin probability `stop_dist / (target_dist + stop_dist)`, per forecast. A forecast that doesn't beat that has told you nothing.
- Report the Brier difference against each baseline with a paired bootstrap interval. Label a cell "not distinguishable from baseline" until the interval excludes zero.
- Use the Brier skill score only as secondary.

**1.9 Reliability buckets and the 20-forecast floor (§0.3).**
- Five buckets over 20 forecasts is about 4 each. Agents cluster at 0.55/0.6/0.65, so several buckets are empty.
- Rewrite: "The Brier score and baseline show from 20 resolved forecasts. The reliability table shows from 50, in quantile buckets of at least 10 each (fewer buckets when n is smaller), with Wilson intervals on the observed rate. Below 50 it says 'not enough forecasts for a reliability table'."
- Overlapping windows on the same instrument (re-proposed after rejection) are not independent. Count one forecast per (instrument, `starts_on`) in calibration, or report the cluster count.

**1.10 Author comparison (§0.2, §0.3).**
- The operator's forecast is optional, so it exists only where the operator chose to forecast. That is selection.
- Compare authors only on the paired subset (proposals with both forecasts). Show each author's overall score separately, labelled as not comparable.

**1.11 Setup attribution (§0.3).**
- Use `order_proposals.setup_id` frozen at creation. `trade.setup` is overwritten at journal review.
- Add to §0.3: "The setup cut uses the proposal's setup at creation, never the trade's."

**1.12 t-test and Holm on R (§0.6, §0.7).**
- R is bounded near −1 (it can be below with gaps and slippage), skewed, and the samples are n < 30. A t-test is not reliable here.
- Holm also needs p-values, not a t-statistic and "threshold". Ruby has no t-cdf.
- Replace with a one-sided sign-flip permutation test of mean R against zero, with a fixed seed and 10,000 draws, pure Ruby. Show a bootstrap interval for the mean beside it.
- Holm runs over the p-values of every hypothesis ever moved to `testing`, with the family size shown.
- Freeze `{n, mean_r, p, m, holm_threshold, trade_ids}` into `hypotheses.evidence` jsonb at the decision. It is currently computed on render from mutable data (reviews, excludes and setup relabels change it), so it isn't reproducible.
- Variants share trades, so tests are positively dependent. Holm is valid under any dependence, so keep it and say it is conservative.

**1.13 Evidence set is post-hoc (§0.5).**
- "The setup's eligible trades opened on or after `holdout_from`" depends on `trade.setup`, which the operator assigns at review (`Trade#review`), and on `excluded_from_stats`, also operator discretion. That defeats pre-registration.
- Rewrite: "Evidence is the closed, included trades whose originating proposal has `setup_id` equal to the hypothesis's setup, was created on or after both `holdout_from` and the hypothesis's own `created_at`, and whose entry was not bootstrapped. `excluded_from_stats` trades are listed beside the result, not silently dropped."
- `holdout_from` must be ≥ the `created_at` date (no backdating).
- `eligible_for_stats` counts closed trades only, so open losers are absent. Show the count and unrealized R of open trades in the hypothesis's evidence beside the result.

**1.14 Decay check (§0.7).**
- A one-sided 5% test on ≥ 10 trades has almost no power. Running it every Sunday is sequential testing, so false alarms accumulate.
- The accepted `expected_mean_r` is also biased up (winner's curse), which produces apparent decay by regression to the mean.
- Cheaper and honest: show rolling mean R since acceptance with a bootstrap interval against `expected_mean_r`, and start the line at n ≥ 20. Drop the "failing check" wording and name a suggested action only when the interval's upper end is below the expectation.
- `expected_sd_r` is unused anywhere. Cut it, or define what reads it.

**1.15 Look-ahead in snapshots (§0.4).**
- `StopCollar::Candles.for` takes `all.last` as the close, and during the session that is today's partial bar. ATR is slightly off. Volume vs the 20-day average is badly wrong, and "close vs averages" is mislabelled.
- Features use bars dated before today, unless the market is closed and the bar is final. Record `last_bar_date` and `partial_dropped`.
- SPY relative strength must use the intersection of dates. Record SPY's last bar date as well.
- `computed_at` is not the data's timestamp. Store both.
- Reword `features` to `{ "version", "computed_at", "bars_through", "spy_bars_through", "values", "missing" }`.

**1.16 Slippage (§0.8).**
- Slippage against the mid at approval, for a limit order that rests, is mostly market drift. It also exists only for orders that filled, so it is adverse-selected (a limit fills when price comes to you).
- Scope it: an entry fill within the same session as the approval is `comparable`; others are `not_comparable` and excluded from the net figure with their count shown.
- A stop-out's real cost is the fill against `planned_stop`, which needs no quote. Compute exit slippage that way.
- Shadow approvals are hand-placed minutes or hours later. Tag them `shadow` and keep them out of net stats.
- Net mean R is a mean over trades that have slippage data, so show the denominator: "net over 7 of 12 trades".

## 2. Anything that lets a model or forecast gate, size or place an order, or edit after the fact

**2.1 `min_expected_r` (§0.8, §1, §4 step 5, §7). Cut it as a guardrail.**
- It makes an agent-supplied probability an input to a gating rule. The agent can inflate `p` to avoid the caution.
- An operator forecast added on the waiting page changes the evaluation, so `check_drift!` in `Submission::Submit` then refuses the approval ("now need acknowledging; re-propose").
- It contradicts the opening line, "Nothing in this phase places, sizes, or blocks an order", since a caution needs an acknowledgement.
- Replace with a display-only line on the proposal page: "Expected R after costs, by the agent's forecast: X (agent's Brier vs baseline: …)". It is not a rule, has no acknowledgement and no `risk_rules` row. Drop the seed, the §1 bullet and the step-5 clause. Remove it from §7.

**2.2 Calibration "never in a prompt" (§0.3) vs the skeptic (§0.9).**
- §0.9 feeds the skeptic "the setup's sample and calibration". This contradicts §0.3 and lets the agent's own score loop back into agent input.
- Reword §0.9 to: "The skeptic reads stored snapshot values through a read tool (`research_summary`), as text rendered by Rails, labelled with n and 'not enough' where applicable. It never computes any statistic."
- The interactive agent, the one writing forecasts, does not see its own calibration. Add that to §0.3.

**2.3 Frozen forecasts (§0.2). "Never edited" is not enforced.**
- Add: forecast columns other than `outcome`, `resolved_at` and `detail` are `attr_readonly`, and a database trigger or `BEFORE UPDATE` check refuses changes to them.
- The resolver is the only writer of `outcome`, and it writes once (`WHERE outcome IS NULL`).
- `made_at` is `DEFAULT now()`, never accepted from a tool or form. `probability` has a bounded scale, `numeric(5,4)`.
- A forecast is created inside the `Proposals::Create` transaction. A refused creation (halted or duplicate) writes no forecast.
- `features`, `quote_at_approval` and `skeptic_note` are written exactly once (`quote_at_approval` inside `start_submission!`'s `attributes`).
- The same applies to hypotheses (§0.5): the statement, rules, `min_sample`, `holdout_from` and expected fields are readonly after create. Only status and decision fields move.

**2.4 Operator forecast added on the waiting page (§0.2, §3).**
- The page shows the agent's probability, so the operator can anchor on or copy it.
- The form hides the agent's probability until the operator submits or the proposal is decided.
- The levels (target, stop, entry) come from the proposal. The operator varies only probability and horizon. Say so; the draft is ambiguous.
- Only an approver can add one (Phase 2 §0.13). The second user reads.

**2.5 Agent's tool contract (§0.2).**
- `propose_order` has no `target_price` input today, and `Proposals.draft` doesn't set `target_price`. Forecast `target_price` must be the proposal's `target_price`, not a second source of truth. Add it to the proposal, then copy it.
- The `required:` array in the schema cannot be conditional on `side`. Enforce in code with `InvalidArguments` for buys.
- An entry with a nil `stop_price` has no forecast (stop is required for the forecast). Refuse the forecast and say why.

**2.6 Hypothesis state changes (§0.5).**
- Who moves `proposed → testing` isn't stated. That move starts the Holm family count, so it needs the same treatment as accept/reject: the approver only, audited, with the reason.
- "Refused before `min_sample` trades" applies to accept and reject. Retire should be allowed at any time.
- "Setups are not gated by hypotheses" is correct. Keep it.

## 3. Contradictions with Phase 2 and 2.5 invariants

**3.1 Audit of every state change (Phase 2 §0.16).** §2 says "one audit row per run with counts". The invariants require an audit row per state change.
- Write one `forecast_created` and one `forecast_resolved` per forecast (with outcome, deciding day, ambiguous/expired), plus the run-level row.
- Add `hypothesis_created`, `hypothesis_testing`, `hypothesis_decided` and `hypothesis_retired`, `skeptic_note_written` (run id, outcome), and `calibration_computed` per run.
- The quote freeze goes in `proposal_approved`'s data. Volume is low.

**3.2 Approve path (§0.8).**
- Fetching a quote inside `first_transaction` would hold the proposal lock across a Schwab call, which Phase 2 §0.6 forbids.
- Fetch the quote before the transaction, after a cheap pre-check (`user.approver? && proposal.approvable?`, so an unauthorised press doesn't spend a call), and pass it in. Rescue `Schwab::RateLimited` and any `Schwab::Error` into `quote_at_approval = { "unavailable" => reason }`.
- `Agent::MarketData.quotes` serves a quote up to 2 minutes old from cache. Record `fetched_at` and `quote_time`, and tag a quote older than 30 seconds `stale`.
- The quote read happens in shadow mode too. It is a read, not an order call. Say so.

**3.3 Page renders (§3).**
- Every new panel (forecasts, snapshots, skeptic note, approval quote, /research, slippage) must read stored rows only.
- State it as an invariant. 2.5 §8 already records that the proposal page can fetch history on a cold cache. Do not add anything that deepens that.
- Computing the t-statistic or permutation test on /research render is fine if it reads only the DB. Add a note saying it must.
- The operator-forecast POST computes `starts_on` from the local `MarketDay` table, not Schwab.

**3.4 Unattended runs read-only (§0.9).**
- The skeptic runs through `Agent::Conversation` with `Agent::Tools.definitions(:scheduled)`. Confirm that excludes `propose_order`, `annotate_trade` and `add_watchlist_item`. The new `research_summary` tool must be `scheduled: true, read_only: true`.
- `AgentRun.served?(kind, date)` dedupes by kind and date. Check that "one run per proposal" doesn't collapse all of a day's skeptic runs into one. `agent_runs` likely needs a `subject` (the proposal) and a uniqueness on `(kind, subject)`.
- The note arrives after commit, possibly after the operator has decided. Show "pending" and never delay approval. A failed run is a line (already stated).
- Skip the skeptic when the proposal is `rejected_by_rules`, since it can't be approved. This is a free cost saving.

**3.5 Rate budget and cadence (§2).**
- The resolver at 17:20 and calibration at 17:25 follow the allocation check at 17:10 and its correlation job, which all share the Schwab budget. Fetch once per distinct symbol, not per forecast.
- The resolver, calibration and Sunday review read the same cache the collar reads.

**3.6 Shadow mode.** The path-based forecast is independent of fills, so it works in shadow. Say so explicitly.
- Slippage in shadow is hand-placement noise (§1.16 above).
- Also add that `quote_at_approval` is frozen in shadow, so the same data can later be compared with a real fill.

**3.7 Slippage in the journal (§1).**
- `Trade#recompute!` is "a pure function of the legs". Compute `slippage` and `slippage_r` there from `order_proposal.quote_at_approval` and the initial entry legs. Don't add a separate writer.
- Nil when there is no proposal (`schwab_direct`, rebalance buys, bootstrapped trades).

## 4. Missing pieces and cheaper designs

- **Rebalance-buy features (§0.4, §4 step 3):** cut them. Rebalance buys carry no forecast and no stop, so they have no R and no outcome to join. They would also add instrument and SPY candle fetches to the 17:10 job. Features apply to entries only.
- **`Proposals.draft` is also used by `evaluate_hypothetical_order`.** Put snapshot computation in `Proposals::Create` or a `Features::Snapshot` it calls, not in `draft`, or every hypothetical evaluation pays for it.
- **Days to earnings:** the key is always "unavailable". Drop the key now and add it with a version bump when a source exists.
- **Calibration snapshot keys (§0.3, §1):** define `key` for `overall` (a fixed value), and say whether a nightly row is appended or replaced. The Brier trend needs history, so append, one row a night.
- **Cut cells:** show author-by-setup only when n supports it. Per author and per setup separately is fine.
- **Void and unresolved counts:** show them in the same panel as every calibration number.
- **Resolver version:** store `resolver_version` in `detail` so a later rule change is distinguishable.
- **Skeptic's own track record:** gap analysis §5 asked that "its hit rate should be journaled". The plan drops it. Say it is deferred rather than silently omitted.
- **Skeptic cost:** it runs on `Agent::MODEL` for every entry. Consider a smaller model, or skip rejected-by-rules and operator entries. This is a §7 decision for the user. The skip-rejected case is not a decision, just do it.
- **Forecast ↔ trade join:** the realized R vs forecast comparison exists via `order_proposal_id`. Say so, since gap analysis §3.1 wanted it.

## 5. Cut

- **`min_expected_r`:** the rule, seed, §1 bullet, step-5 clause and §7 item (see 2.1).
- **Rebalance-buy features** and the always-null `days_to_earnings` key (§4 above).
- **`expected_sd_r`,** unless the decay check is specified to use it.
- **The decay check's "failing check" test** and the "Brier trend" line below n ≈ 20 (see 1.14).
- **`resolves_on` as a stored fact,** replaced with an estimate (see 1.3).
- **Skeptic runs on `rejected_by_rules` proposals.**

Suggested wording for the §0 preamble, to make the new constraints explicit: "Every number on a page is read from a stored row. No forecast, probability, calibration figure or model-written text is an input to a guardrail, to sizing, or to the choice of what is proposed."
