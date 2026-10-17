# Phase 2.6 plan review

The draft holds up overall. There are three serious problems:

- **The `min_expected_r` rule lets a forecast gate an order** (§0.8). A low probability blocks approval until it's acknowledged, which also gives everyone a reason to report a higher one.
- **The skeptic can't be built as drafted** (§0.9). The database allows only one agent run of each kind per day.
- **Several numbers can be tuned after the fact.** A trade's setup can be changed, or the trade excluded, after its outcome is known. A hypothesis's `holdout_from` can be set in the past. And nothing ties a trade to one variant rather than another.

Each finding below gives the section and the change I propose.

## 1. Statistical defects

**1.1 §0.1, scoring the price path instead of the fill.** A limit buy below the market can "hit" its target without the trade ever existing. Meanwhile §0.8's expected R, p × reward-to-risk − (1 − p), assumes p is the chance of target-before-stop *once filled*. The scoring rule and the formula measure different things.
*Rewording:* "The clock starts on the first session, on or after `starts_on`, whose low is at or below `entry_price` (a marketable limit starts at once). If no session touches the entry within the horizon, the forecast is `void` with reason `no_entry`. These are counted and shown beside n, never hidden." This still scores rejected and expired proposals, so most of the extra sample survives. Add it to §7 for the user: it changes what "hit" means.

**1.2 §0.1, a forecast already settled when it's made.** If the last price when the forecast is made is at or above the target, or at or below the stop, it's a free hit or miss.
*Fix:* refuse to record it, and freeze `price_at_forecast` on the row.

**1.3 §0.1 and §0.2, `resolves_on` from Schwab's calendar.** `MarketDay.for` fetches one date at a time, and `next_trading_day_after` returns nil on fallback rows (`app/models/market_day.rb:46`). Counting 60 trading days ahead means dozens of possible Schwab calls. They would run inside `Proposals::Create` (whose own comment says no lock is held across a call) or the operator's form POST, and they can fail.
*Fix:*
- Store `starts_on` only, defined as "the first session whose regular open is after `made_at`". This settles the pre-market case.
- Define the horizon as "the first `horizon_days` daily candles dated on or after `starts_on`" and count bars in the history the resolver already reads.
- Resolve as expired only once that last candle exists. A missing candle waits; it is never a miss.

**1.4 §0.1, ambiguous days counted as the stop.** This biases every score against the forecaster, and with tight ATR stops on volatile names it won't be rare.
*Fix:* make `ambiguous` its own outcome. Calibration then shows the hit rate as a range: ambiguous counted as a miss, and as a hit. Optionally, the resolver can break the tie from minute candles when Schwab still serves them for that day (a new verify item).

**1.5 §0.1 and §5, splits.** If `pricehistory` is split-adjusted, every bar is restated after a split, while the stored levels stay in pre-split units. An unfilled proposal has no trade, so there's no `Ledger#ratio` to scale by.
*Fix:* scale the levels by the journal's ratio when a trade exists. Otherwise, a one-day move over 35% inside the window makes it `void` with reason `possible_split`, the same test correlations use (2.5 §8, step 5).

**1.6 §0.1, void forecasts drop out of the sample.** Delistings tend to follow collapses (a stop) or buyouts (a target), so dropping voids biases the hit rate.
*Fix:*
- The resolver walks every open forecast each night and stores `checked_through`, so a forecast is settled by the candles it saw before its history vanished.
- A name whose history stops with the last low at or below the stop is a `miss`.
- Every calibration figure shows the void count next to n.

**1.7 §0.3, the Brier baseline.**
- "Always forecasting the base rate", computed on the same sample, is the best constant in hindsight. That is look-ahead for the baseline.
- A constant baseline is also weak, because hit rates depend mostly on where the target and stop sit. A forecaster can beat it just by reading the distances.

*Fix:* use as the baseline the no-skill barrier probability, (price − stop) ÷ (target − stop), measured in log prices from `price_at_forecast`. The forecast must beat what the distances alone imply. Also show the in-sample base rate, labelled as such, and the mean reward-to-risk per author.

**1.8 §0.3, reliability buckets.** Five buckets over 20 forecasts is about 4 per bucket. Also, per-setup and per-author cuts will rarely reach 20.
*Fix:* show each bucket's n with a Wilson interval and grey out buckets under 10, or use two buckets until overall n is at least 100.

**1.9 §0.3, overlapping forecasts.**
- Re-proposing the same idea (as §0.2's "a correction is a new proposal" requires) creates a second forecast over the same window.
- Forecasts open at the same time share market moves.

Both make n look bigger than it is.
*Fix:* calibration counts at most one forecast per author, instrument and overlapping window (the first). It also shows the number of distinct instruments and weeks beside n.

**1.10 §0.4, features reading today's partial candle.** A proposal made at 11:00 may read today's unfinished bar: "close" is the live price, today's volume is partial and the ATR range incomplete. One drafted at 17:10 reads a finished bar, so features aren't comparable across proposals.
*Fix:*
- Use only candles dated before the session in progress (or that day's own candle once its regular close has passed).
- Store each series' last bar date, the instrument's and SPY's, in `values`.
- If SPY's last bar differs from the instrument's, the relative-strength feature is `missing`.
- A stale cache entry (`stale: true`, kept for 12 hours) counts as missing; go through `StopCollar::Candles.for`, which refuses it.

**1.11 §0.5, setups can be assigned after the outcome.** `Trade#review` sets or changes the setup after the trade has closed, and `exclude!` drops trades from the stats. So the evidence for a hypothesis can be chosen after seeing each trade's R. That is look-ahead in the sample.
*Rewording:* "Evidence is the trades whose entry proposal named the hypothesis at creation (`order_proposals.hypothesis_id`, frozen) and was opened on or after `holdout_from`. Excluded trades still count, shown with their exclusion reason. A setup reassigned at review never moves a trade into or out of a hypothesis."
This also fixes the variant problem. Rules are free text, so today a parent and a variant with the same `setup_id` and `holdout_from` get identical evidence, and Holm across them means nothing.

**1.12 §0.5, holdout dates in the past.** Nothing stops `holdout_from` being set before the hypothesis existed.
*Fix:* a check constraint `holdout_from >= created_at::date`, never edited, and only proposals created after the hypothesis row can name it.

**1.13 §0.5 and §0.6, checking until it looks good.** The t-statistic is shown continuously and accepting is allowed any time after `min_sample`. Accepting the first time it crosses the bar inflates false positives.
*Fix:*
- Judge only the first `min_sample` eligible trades, frozen.
- Show no statistic until then.
- Accept or reject on that verdict alone. Trades after that only feed the decay check.

**1.14 §0.6, the t-test and Holm.**
- R is cut off near −1, gaps below that, and is skewed to the right. A t-test at n of 10 to 30 overstates what it shows.
- Holm needs a fixed family of tests. Here the family grows over time, so a hypothesis accepted today could fail retroactively when a sixth is added.

*Fix:*
- Report n, mean R, and a bootstrap 95% lower bound on mean R with a fixed seed, so it can be reproduced.
- Use a Bonferroni bar of α ÷ m, where m is the number of hypotheses ever moved to `testing`, counted when the decision is made.
- Freeze `tests_counted`, the threshold and the statistic on the row at decision. Still counted, never rewritten.

**1.15 §0.7, the decay check.**
- A weekly one-sided test at 5%, starting at 10 trades, raises false alarms simply by being repeated every Sunday, and at n = 10 it can barely detect anything.
- "The setup's Brier trend" isn't defined.

*Fix:*
- Re-test only when a trade has closed since the last check.
- Use a z-test against the declared `expected_mean_r` and `expected_sd_r`, which were declared before the evidence and give more power than the sample's own spread. A CUSUM on R would also work.
- Cut the Brier trend, or define it as two windows of at least 20 each.

## 2. Anything that lets a model or forecast gate, size or place an order, or be edited later

**2.1 §0.8, `min_expected_r` (the main finding).**
- A caution adds an acknowledgement, so the forecast now gates approval.
- When the operator adds a forecast to a waiting proposal, the next evaluation finds a new warning, and `Submission::Submit#check_drift!` refuses approval with "re-propose" (`app/models/submission/submit.rb:59`).
- It rewards a higher reported p (the agent's or the operator's), which breaks the forecast log, since a score only stays honest when nothing else rides on the number.
- It doesn't say which author's p it uses when both exist.
- It reads "half the frozen spread", but the quote is only frozen at approval, after the creation-time evaluation.
- Seeding a new rule also makes every waiting proposal fail approval with "re-propose".

*Fix:* cut it from 2.6. Show expected R on the proposal page as information only, worked out from the setup's observed hit rate, never from the forecast. Add it back as a rule only once calibration exists.

**2.2 §0.2, frozen only by convention.** *Fix:*
- A database trigger refuses any UPDATE of a forecast's claim columns, and allows `outcome`, `resolved_at`, `detail` and `checked_through` to be written only while `outcome IS NULL`.
- No DELETE.
- The model is read-only apart from the resolver.

**2.3 §0.2, the operator's forecast is anchored.** By the time the operator adds one, they've seen the agent's probability, the skeptic note and the price since.
*Fix:* hide the agent's p and the skeptic note on the add form until the operator saves theirs or declines, and record `saw_agent_forecast` on the row. Also report the share of the operator's proposals that carry a forecast, since an optional forecast picks its own easy cases.

**2.4 §0.2, the tool and draft shapes.**
- `propose_order` has no `target_price` input today.
- `stop_price` is optional (`app/models/agent/tools/propose_order.rb:10`).
- `Proposals.draft` takes no target, although `order_proposals.target_price` exists and the journal adopts it as `planned_target`.

*Fix:* require `stop_price` and `target_price` on agent entries. Pass `target_price:` through `draft` and write the agent's forecast from the proposal's own columns, so the two can't disagree. An operator forecast with a different target is its own row and leaves the proposal alone.

## 3. Contradictions with the Phase 2 and 2.5 invariants

**3.1 §0.8, a Schwab call under the row lock.** If `quote_at_approval` is fetched inside `first_transaction`, it runs under `@proposal.lock!`. Also, `Agent::MarketData.quotes` re-raises `Schwab::RateLimited` (`app/models/agent/market_data.rb:69`), which would turn a rate limit into a failed approval.
*Fix:* fetch before transaction one, rescue every error including the rate limit, and pass `{bid, ask, mark, quote_time, fetched_at, stale | error}` in. It never refuses.

**3.2 §0.9, one skeptic per day.** `index_agent_runs_one_per_kind_and_day` is unique on `(kind, market_date)` where status isn't failed, so the second skeptic of the day fails to insert.
Also:
- `AgentRun#deliver!` would email it.
- `AgentRun#title` would raise, since `TITLES` has no `skeptic` key.
- `Agent::Context` takes only kind and date.

*Fix:*
- Add `agent_runs.order_proposal_id`, unique for kind `skeptic`, and narrow the daily index to the scheduled kinds.
- No delivery for the skeptic.
- A context that takes the proposal.
- Skip `rejected_by_rules` proposals: there's nothing to decide.

**3.3 §0.3 and §0.9, calibration in a prompt.** §0.3 says calibration is "never in a prompt", but the skeptic prompt reads "the setup's sample and calibration".
*Fix:* pick one. I'd let only the skeptic read the stored snapshot, never the proposing agent, and reword §0.3 to say that.

**3.4 §0.7 and §2, the Sunday review.** The draft has the Sunday review "computing" a t-test and reading "the prompt". `Agent::SundayReviewJob` is a stub with no model call.
*Fix:* a Saturday job writes `decay_checks` rows (audited, like 2.5's `DiagnosticsJob`), and the Sunday email reads stored rows. Delete "prompt" from §2.

**3.5 §2, audit coverage.** "One audit row per run" doesn't meet "every state change audited", and the draft names no audit for creating forecasts or hypotheses, or for `proposed → testing`, which the multiple-testing count depends on.
*Fix:* add `forecast_recorded`, `forecast_resolved` (outcome and deciding day), `hypothesis_created`, `hypothesis_status_changed` (from, to, and the frozen statistic), and one audit row per calibration run.

Nothing here renders a page from Schwab, provided §3.1 holds and the forecast form doesn't compute a calendar (§1.3).

## 4. Missing pieces or cheaper designs

**4.1 §0.8, slippage double-counts.** `Trade#recompute!` already builds `realized_r` from the broker's net cash amounts, so it is already net of what was paid. Subtracting slippage again counts it twice.
*Rewording:* "Realized R is net. Gross R is what the trade would have made at the approval mid. The difference is the cost."

**4.2 §0.8 and §1, slippage on the wrong record.**
- A trade carries one `order_proposal`, the entry's (`Journal::Linker#adopt_proposal`).
- Exits are separate proposals, and stop-outs are bracket children nobody approved.
- A resting limit filled later measures price movement, not cost.
- In shadow mode it measures the delay before hand placement.

*Fix:*
- Record slippage per leg, through `activity → order → order_proposal`.
- Measure stop-out slippage against the planned stop. That is the real cost, and the journal can compute it today with no new quote.
- Treat entry spread as cost only for marketable limits.
- Label shadow legs "placed by hand".

**4.3 §4, build order.** The approval quote is a small change that starts collecting data. Move it to step 1.

**4.4 §0.9, the skeptic's own record.** The gap analysis (§5) asked for the skeptic's hit rate to be tracked, and the draft dropped it.
*Cheap fix:* the skeptic names one risk category from a fixed list, stored with the note, and the outcome is joined to it later.

**4.5 §2, cadence.** With n in the tens, nightly calibration snapshots add nothing. Run the calibration job weekly. The resolver still runs nightly, for `checked_through` (§1.6).

## 5. Cut

- `min_expected_r` as specified (§2.1).
- The live t-statistic and Holm, replaced as in §1.14.
- The Brier trend in the decay check, unless it is defined (§1.15).
- Nightly calibration snapshots.

## Additions to §7, for the user to confirm

- Scoring forecasts from the first session that touches the entry price, with untouched forecasts `void` and counted (§1.1).
- `ambiguous` as its own outcome, shown as a range (§1.4).
- Hypothesis evidence limited to proposals that named the hypothesis when they were created (§1.11).
