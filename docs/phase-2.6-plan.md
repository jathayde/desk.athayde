# Phase 2.6 plan: the quant research track

Source of truth: `docs/quant-research-gap-analysis.md` §3 and §4, and PRD §6 (Phase 2.6). Phases 2 and 2.5 are built and reviewed; their conventions hold (secrets in credentials, CUSIP identity, every "logged" action an `audit_events` row, no live Schwab calls in tests, unattended runs read-only, shadow mode, `bin/ci` green per step, DHH and counselors review per step). **Nothing in this phase places, sizes, or blocks an order.** It measures: whether the desk's forecasts mean anything, whether its setups have an edge that survives costs and fresh data, and when an edge is decaying. Its output is evidence for the human, and for the PRD's Phase 3 gate ("only after the journal shows positive expectancy over a real sample").

**Invariant for the phase:** every number on a page is read from a stored row; no forecast, probability, calibration figure, or model-written text is an input to a guardrail, to sizing, or to the choice of what is proposed; nothing a decision rests on is editable after the fact.

**User's answers (2026-10-16):** forecasts from both the agent and the operator, scored separately; a forecast is required on every agent entry and optional on the operator's; the research universe is holdings, the watchlist, and SPY (Schwab data only, time-series ideas only); build in the recommended order, the stored price history and backtester held until the forecast log has a few months of data.

**Plan review (2026-10-16, `agents/counselors/phase26-plan/1792200694-phase26-plan/`):** both reviewers (claude-opus, claude-sonnet) agreed on the material changes, all folded in below: forecasts conditional on the entry being touched (§0.1); horizons counted in candles, no calendar lookahead (§0.1); a geometry baseline (§0.3); hypothesis evidence named at proposal creation, judged once on a frozen first sample (§0.5–0.6); a resampling test with a Bonferroni bar frozen at decision instead of a live t-statistic with Holm (§0.6); `min_expected_r` cut as a rule and shown as information (§0.8); the skeptic given its own run identity (§0.9); immutability enforced in the database (§0.2); per-row audits (§0.11); the approval quote moved to step 1.

## 0. Decisions and assumptions

1. **A forecast is a claim about the price path once the entry is touched.** "Within `horizon_days` sessions of the entry being touched, the daily high reaches `target_price` before the daily low reaches `stop_price`," with a `probability` in (0, 1) and an `author` (`agent`, `human`). That is what the forecaster actually estimates (the chance of target-before-stop once in), and it is scored on Schwab's daily candles whatever happened to the order, so a rejected, expired, or unfilled proposal whose entry the market touched is still scored, and the score is independent of the operator's exits and of shadow mode.
   - **The window opens** on the first daily candle dated after `made_at` (or on `made_at`'s own date when it was made before that session's regular open), so no candle that includes range from before the forecast is ever read. No calendar is consulted: the candles are the calendar.
   - **Entry:** the first candle within `entry_window` (5) candles of the opening whose low reaches `entry_price`; a marketable limit needs no rule of its own, since its opening candle's low almost always reaches it, and a gap above the limit is rightly no fill. On the entry candle only the stop is tested (daily bars cannot order the fill against the levels inside one day; a stop touched there is a miss, marked `ambiguous`); the target counts from the next candle. No touch within the window: `void`, reason `never_entered`, counted and shown beside every n.
   - **Resolution:** the horizon is the first `horizon_days` candles after the entry candle. A candle touching both levels counts as the stop (the headline, conservative) and is marked `ambiguous`; calibration also shows the range with ambiguous days counted as hits. A horizon whose last candle exists with neither level touched is a `miss`, marked `expired`; a missing candle waits, it is never a miss. Only final candles count (dated before today, or today's after the regular close), and a stale cache entry (`Agent::MarketData`'s 12-hour fallback) is refused.
   - **Splits and endings:** a candle for `reference_close`'s date more than 2% from it, or a one-day move over 35% inside the window (the 2.5 correlation guard), voids with reason `split`, never rescaled silently. A history that stops before the horizon ends (after following `Instrument#predecessor_instrument`) is a `miss`, marked `ended_early`, unless a level already settled it; `void` for `data_unavailable` only after five failed nights. Void reasons are a fixed list: `never_entered`, `split`, `data_unavailable`; a name that ended before its entry was touched is `never_entered`.
   - The rule is a pure function, `Forecast::Resolution.call(forecast, candles)`, tested against fixtures (gap through a level, equal touch, ambiguous, entry-day stop, split, short history, never entered), with `resolver_version` stored in `detail`.
2. **Forecasts are rows, one per author per proposal, frozen by the database.** `forecasts` (`order_proposal_id`, `author`, `user_id`, `probability` numeric(5,4), `horizon_days`, `entry_price`, `target_price`, `stop_price`, `reference_close` and its `reference_on` bar date, `made_at` default now(), `saw_agent_forecast`, `checked_through`, `outcome`, `void_reason`, `resolved_at`, `detail` jsonb with the entry day, deciding day, `ambiguous`/`expired`/`ended_early`). A trigger refuses any update to the claim columns, lets `outcome`, `void_reason`, `resolved_at`, `detail`, and `checked_through` move only while `outcome IS NULL`, and refuses deletes; `made_at` is never accepted from a form or a tool. A forecast is created inside the proposal's own transaction (a refused creation writes none), and refused unless `stop_price < reference_close < target_price`, so no forecast is settled when it is made. The levels always come from the proposal's own columns, so the two never disagree: `propose_order` gains a `target_price` input, and on entries (buys that open exposure) the tool requires `stop_price`, `target_price`, `probability`, and `horizon_days` in code (the schema's `required` cannot depend on the side), refusing without them; `Proposals.draft` carries `target_price:` through. The manual form offers probability and horizon, optional. The operator can add their own (probability and horizon against the proposal's levels) on a waiting proposal's page until it is decided, approvers only; the form hides the agent's probability and the skeptic note until the operator saves or declines, and `saw_agent_forecast` records whether they had seen them. A correction is a new proposal. Exits carry no forecast in 2.6.
3. **Calibration is a stored read model, written weekly, never in the proposing agent's prompt.** Per author, per setup (the proposal's `setup_id` at creation, never the trade's), and overall (key `all`): n, the void and unresolved counts, distinct instruments, hit rate (and the ambiguous-as-hit range), Brier score, and two baselines: each forecast's own baseline (`Research::Baseline`), the chance that a price with no expected drift, at the forecast's reference volatility (20 daily log returns, frozen), meets the claim under the resolver's own rules over its horizon, computed once and frozen with the forecast, which a forecast must beat to have said more than its levels, horizon, and the tape did; and the in-sample base rate, labelled as hindsight. (The draft's `ln(entry/stop) ÷ ln(target/stop)` ignored the horizon and flattered any forecaster who shaded down; the step 2 review replaced it.) The difference against the baseline carries a bootstrap interval drawn by week (fixed seed); until it excludes zero the cell reads "not distinguishable from the baseline". Overlapping forecasts by one author on one instrument count once (the first). Authors are compared only on proposals carrying both forecasts; each author's own score is shown, labelled not comparable, beside the share of the operator's proposals that carry one. The Brier figures show from 20 resolved forecasts; the reliability table from 50, in quantile buckets of at least 10, with Wilson intervals; below each floor the cell says so. `calibration_snapshots` (as_of, scope, key, figures jsonb), appended each Saturday so the history is kept.
4. **Decision snapshots are what the desk saw, frozen at the entry proposal, with a formula version.** On entries only (rebalance buys carry no stop, no R, and no outcome to join): ATR(14) as a fraction of close, close vs its 20/50/200-day simple averages, 63-day return minus SPY's, volume vs its 20-day average, the account's open-risk ratio. Computed in `Proposals::Create` (not `draft`, which hypothetical evaluations also call) from final candles only, through `StopCollar::Candles.for` (which refuses a stale entry); a feature the history cannot support, or SPY's last bar differing from the instrument's, is `null` with the reason in `missing`. `order_proposals.features` jsonb, written once: `{ "version" => 1, "computed_at", "bars_through", "spy_bars_through", "values" => {…}, "missing" => {…} }`. Earnings are left out until a source exists (a version bump). Joined to outcomes later; nothing reads it to decide.
5. **Hypotheses are written before the evidence, and every variant is a row.** `hypotheses` (`statement`, `setup_id`, `rules` text, `min_sample`, `holdout_from` date, `expected_mean_r`, `status` in `proposed`, `testing`, `accepted`, `rejected`, `retired`, `parent_id` for a variant, `evidence` jsonb frozen at decision, `decided_at`, `decided_by_id`, `decision_note`). The claim columns are frozen by the same trigger as forecasts; `holdout_from >= created_at::date`. A changed parameter is a new row with `parent_id`, never an edit. **Evidence is named at creation:** an entry proposal can name one hypothesis in `testing` (`order_proposals.hypothesis_id`, frozen); the hypothesis's evidence is the trades whose entry proposal named it, created on or after `holdout_from`. A setup relabelled at journal review never moves a trade in or out, and excluded trades still count, listed with their reasons; open trades are shown beside the result with their unrealized R. Moving to `testing`, accepting, rejecting, and retiring are the approver's, audited with a reason; retire is allowed at any time. Setups are not gated by hypotheses (the journal still names setups freely); a setup with no accepted hypothesis is shown as "unregistered".
6. **One look, on a frozen sample, against a bar that counts every test.** No statistic is shown before the sample is complete: the first `min_sample` named entries that became trades, in the order proposed, all closed with an R. The verdict on them: n, mean R, a one-sided centred-bootstrap p-value of mean R above zero (no symmetry assumed, since R is skewed), and the lower bound at the bar's level (10,000 draws, fixed seed, pure Ruby). The bar is Bonferroni, α ÷ m with α = 0.05 and m the hypotheses tested by the time the sample completed. It clears when p is at or under the bar and the lower bound is above zero. The verdict, m, the bar, and each trade's R are frozen into `evidence` at the decision, or at a retirement of a complete sample. Accepting needs a verdict that clears; rejecting and retiring do not. Later trades feed only the decay check. Bonferroni rather than Holm because the family grows: a frozen Holm verdict would be wrong by the next test. With desk's sample sizes most rows will read "not enough trades", and that is the honest answer.
7. **The decay check compares live trades with what was declared.** A Saturday job (`Research::DecayJob`, like 2.5's diagnostics) writes a `decay_checks` row per accepted hypothesis, only when a trade has closed since its last row and from 20 trades after the frozen sample: mean R and its bootstrap interval against `expected_mean_r`. When the interval's upper end is below the expectation on two looks in a row, the row names a suggested action (a smaller per-setup `max_risk_per_trade`, or deactivating the setup), which the operator takes in the rule editor or on the setup page. Nothing is changed by the check. No Brier trend in 2.6.
8. **Costs are measured from what was actually seen.**
   - **The approval quote:** before the approval's first transaction, after the cheap checks (an approver, an approvable proposal), the approve fetches the instrument's quote and passes `quote_at_approval` in (`bid`, `ask`, `mark`, `quote_time`, `fetched_at`, `stale` when older than 30 seconds, or `unavailable` with the reason). Every error, a rate limit included, is recorded and never refuses the approval; the Schwab call is never made under the row lock. It is a read, made in shadow mode too, and frozen in the `proposal_approved` audit data as well.
   - **Slippage per leg**, computed in `Trade#recompute!` from the legs: an entry filled in the session it was approved is `comparable`, measured against the frozen mid; one filled later measures the market's drift, not cost, and is `not_comparable`; a shadow leg is placed by hand and is tagged `shadow`, kept out of the net figure. A stop-out is measured against the planned stop, which needs no quote. Nil when there is no proposal.
   - **Realized R is already net** of what was paid (it is built from the broker's net amounts). `Setup#recompute_stats!` adds gross R, what the comparable trades would have made at the approval mid, and the difference is the cost, always with its denominator ("over 7 of 12 trades").
   - **Expected R is shown, never judged:** each forecast's `p × reward-to-risk − (1 − p)` is a line on the proposal page beside its author's calibration. No `min_expected_r` rule, no acknowledgement, no `risk_rules` row.
9. **The skeptic writes a note, never a verdict.** After an entry proposal is created and committed (agent or operator; skipped when the rules rejected it), a background run writes the strongest case against it: thesis staleness, earnings unknown inside the horizon, the setup's sample and calibration, cost against expected R, what the features show. It runs through `Agent::Conversation` with the scheduled, read-only tools and a new read-only `research_summary` tool that returns the stored calibration and hypothesis rows as text rendered by Rails (it computes nothing). The proposing agent never sees calibration. `agent_runs` gains `order_proposal_id`, unique for kind `skeptic`, and the one-run-per-kind-per-day index narrows to the scheduled kinds; the skeptic is never delivered by email, has a title, and takes the proposal as its context. The note, `order_proposals.skeptic_note` with `skeptic_run_id` and one `skeptic_risk` from a fixed list (`thesis`, `timing`, `sample`, `cost`, `trend`, `other`) so its record can be joined to outcomes later, is shown on the proposal page beside the guardrails as "pending" until it arrives; it never delays an approval and adds no acknowledgement, and a failed run is a line saying so. Its cost shows on the system page with the briefs.
10. **Held for later (not built in 2.6):** the stored `daily_bars` history and the walk-forward backtester (gap analysis §3.6). The forecast log and hypotheses will show after a few months whether they are worth building; the candles the resolver and the snapshots read already come from Schwab's one-year history.
11. **Every state change is an audit row:** `forecast_recorded`, `forecast_resolved` (outcome, entry and deciding day), `hypothesis_created`, `hypothesis_status_changed` (from, to, reason, the frozen verdict), `decay_check_recorded`, `skeptic_note_written` (run, risk), and one row per resolver and calibration run with counts. The approval quote rides in `proposal_approved`.

## 1. Data model

- `forecasts` (§0.2): unique `(order_proposal_id, author)`; checks: `probability > 0 AND probability < 1`, `horizon_days BETWEEN 1 AND 60`, `stop_price < reference_close AND reference_close < target_price`, `stop_price < entry_price`, `outcome IN ('hit', 'miss', 'void')` or null, `void_reason` in the list and present exactly when void; the immutability trigger.
- `calibration_snapshots` (§0.3): unique `(as_of, scope, key)`; `scope` in `overall`, `author`, `setup`, `paired`.
- `order_proposals`: `features` jsonb (§0.4), `quote_at_approval` jsonb (§0.8), `hypothesis_id` (§0.5), `skeptic_note` text, `skeptic_risk`, `skeptic_run_id` (§0.9).
- `hypotheses` (§0.5) with the immutability trigger and the holdout check; `decay_checks` (§0.7).
- `trades`: `gross_r` and per-leg slippage in `detail` or columns, decided at step 5 against the leg model (§0.8).
- `agent_runs`: `order_proposal_id`, kind `skeptic`, the daily index narrowed.

## 2. Jobs and cadence

- `Research::ResolveForecastsJob` 17:20 trading days: every open forecast, one candle fetch per distinct symbol through the shared cache, `checked_through` advanced; a rate limit stops the run and the rest wait a night. One audit row per forecast resolved, one per run.
- `Research::CalibrationJob`, `Research::DecayJob` Saturday after the diagnostics: the snapshots and the decay rows.
- `Research::SkepticJob` enqueued by `Proposals::Create` for entries, after commit.
- The Sunday email reads the stored rows; nothing is computed in it.

## 3. Screens (stored rows only)

- Proposal form and the agent tool: target, probability, horizon (§0.2). Proposal page: the forecasts (author, probability, horizon, expected R, once resolved the outcome), the operator's blind add form while it waits, the decision snapshot with its version and bar dates, the hypothesis named, the skeptic note, and the frozen approval quote once approved.
- `/research` (desktop): calibration per author, per setup, and paired, with both baselines, the intervals, and the void counts; hypotheses with their frozen verdicts, m, and bar; the form to write a hypothesis or a variant; testing, accept, reject, retire.
- Journal trade page: slippage per leg with its tag, gross and realized R.
- Sunday email: a Research section (calibration headline per author, hypotheses ready for a verdict, decay lines).

## 4. Build order (green `bin/ci`, DHH and counselors review, commit per step)

0. Counselors plan review of this document; findings folded in (done).
1. Forecasts and the approval quote: the table and trigger, the tool and form fields, `target_price` through `draft`, the operator's blind add, `Forecasts::Resolution` with its fixtures, the resolver job, audits; the quote fetched before the approval and frozen.
2. Calibration: the Saturday snapshots, both baselines and intervals, the `/research` calibration view, the Sunday headline.
3. Decision snapshots: the features on entries, with version, bar dates, and missing reasons; shown on the proposal page.
4. Hypotheses: the table and trigger, the proposal's `hypothesis_id`, the research screen's form and list, the frozen verdict, testing/accept/reject/retire.
5. Decay check and costs: the Saturday decay rows and Sunday lines; per-leg slippage, gross R, the expected-R line.
6. Skeptic note: the run identity, job, prompt, `research_summary` tool, and proposal-page panel.
7. Playwright for a forecast added and resolved, the research screen, and a hypothesis decided; phase-level DHH and counselors review.

## 5. Verify on approval

Whether Schwab's daily candles carry the regular session's high and low only (an after-hours print beyond the session range would resolve a forecast early); whether `pricehistory` is split-adjusted (item 65; the 2% reference check voids rather than mis-resolves either way); the quote fields at approval time (bid/ask present and current outside the session); whether Schwab serves minute candles far enough back to break an ambiguous day (not built; would replace stop-wins).

## 6. Not built in Phase 2.6

The stored daily history and the backtester (§0.10); a screened research universe or cross-sectional ideas; earnings dates (no source); any automatic sizing, gating, or setup deactivation; `min_expected_r` as a rule (until calibration exists); forecasts on exits; the agent writing hypotheses; a Brier trend in the decay check.

## 7. For the user to confirm (recorded, not blocking the build)

- Forecasts conditional on the entry being touched within five sessions, untouched ones void and counted (§0.1); ambiguous days counted as stops in the headline, with the range shown.
- One-day moves voided only on a split ratio, every other move scored (§0.1, from the step 1 review); an entry whose levels cannot be measured is proposed without a forecast rather than refused (§8).
- 20 resolved forecasts before a Brier figure, 50 before a reliability table.
- `min_expected_r` dropped as a rule; expected R shown on the page instead.
- Hypothesis evidence limited to proposals that named it at creation; one verdict on the first `min_sample` trades, with a Bonferroni bar.
- The skeptic on every entry, the operator's included, at one agent run each on `Agent::MODEL` (a smaller model, or agent entries only, would cut the cost).
- Setups left ungated by hypotheses (§0.5).
- Added during the build, from the step and phase reviews (§8, §9), each a number or a rule you did not choose:
  - an entry counts as evidence for a hypothesis about a setup only when the entry names that setup itself;
  - a hypothesis verdict on fewer than 30 trades is labelled indicative;
  - a calibration interval is shown only from 8 distinct weeks of forecasts;
  - a decay flag needs two looks in a row below what was declared, the second adding at least 5 trades;
  - an entry's cost is comparable only when approved inside the regular session and filled within 15 minutes;
  - the skeptic runs on at most 25 entries a day, retries a failed run once, and works within 6 turns, 8 tool calls, and 120,000 input tokens.

## 8. As built

**Step 1 (forecasts and the approval quote).** As planned, with these specifics:
- The reference close is frozen on the proposal (`order_proposals.reference_close`, `reference_on`), computed in `Proposals.draft` for entries from `StopCollar::Candles#final` (the last candle whose regular close has passed, by the stored calendar). Every forecast on the proposal copies it, so the operator's add on a waiting page reads no Schwab history.
- `starts_on` is stored, computed from `made_at` and the stored calendar's regular open (09:30 when no row exists). The resolver never consults the calendar; the candles are the calendar.
- `Forecast::Resolution` is pure and leaves a forecast open when the candles run out. `Research::ResolveForecastsJob` decides what running out means: five nights without usable history void it as `data_unavailable`, a delisted name with no successor is a `miss` (`ended_early`) once entered and `never_entered` otherwise, and a delisted name with a successor is read through the successor's symbol.
- A forecast that cannot be recorded refuses the proposal it came with. It is recorded before the evaluation, so the refusal never rolls back a halt the rules engaged.
- The resolver consults the stored calendar only for the closed days that excuse a gap in the candles; it never reads a future session from it.
- The approval quote is fetched straight from Schwab, not from the 2-minute tool cache, for an approver pressing on an approvable proposal. It is marked `stale` when Schwab's quote time is more than 30 seconds older than the fetch, which outside the session it usually is. A quote whose CUSIP is not the instrument's is recorded as unavailable.
- The operator's add form is hidden from the reader. The agent's forecast is hidden from the approver until they add theirs, choose to look first, or the proposal is decided. Looking is a POST that writes an `agent_forecast_revealed` audit row, and `saw_agent_forecast` is derived from that row, never from the form.
- **Step review (DHH; counselors, claude-opus and claude-sonnet, `agents/counselors/phase26-step1/`), all taken:**
  - A delisted name whose history has gone empty now settles through the "ended" rule. The entry is read from the forecast's stored detail, so a forecast that entered on an earlier night is a `miss`.
  - Failed nights are counted in a row; a night that reads candles resets the count. A skipped session, a missing reference candle, and history ending before the last session it should hold each count as failed nights.
  - The 35% one-day rule became the split-ratio rule (§0.1).
  - Rounding happens before validation, and the level checks the database enforces are also said in words.
  - A forecast made on a closed day starts that day.
  - **A forecast never decides what is proposed.** Levels the desk cannot measure (no final close, or the last close already outside the stop and target) leave the entry without a forecast. This is audited as `forecast_not_recorded` and reported in the tool's answer, and the proposal is not refused. An author's own mistake (probability or horizon out of range) still refuses it.
  - Database freezes:
    - The trigger freezes the whole row, less the result columns, so a column added later is frozen by default.
    - The open-row check handles NULL.
    - `order_proposals.reference_close`, `reference_on`, and `quote_at_approval` are frozen once set.
    - An outcome and its audit row are written in one transaction.
  - One failing forecast no longer holds up the rest of its instrument.
  - The tool tells the agent not to restate its probability in the thesis.
- **Caveat for step 2:**
  - The agent's probability is a tool argument in the operator's own MCP session, so "blind" holds on the page, not in that session.
  - The operator may add hours later, with a later `starts_on`.
  - Paired calibration therefore pairs only forecasts with equal `starts_on`, and never claims the two forecasts were independent.

**Step 2 (calibration).** As planned, with these specifics:
- `Research::Calibration` computes the cuts and their figures, and `Research::Stats` holds the bootstrap and Wilson interval. A fixed seed (2026) and 10,000 draws keep every interval reproducible.
- The overlap rule counts a forecast once per author and name. A later forecast whose `starts_on` falls inside the last counted one's planned window (`window_ends_on`) is the same bet again; it is counted in `overlapping` and left out of the score.
- `CalibrationSnapshot.record!` replaces a day's rows on a rerun and keeps every earlier Saturday.
- The pair rule is that both forecasts are on one proposal with equal `starts_on`, the operator's made blind.
- `/research` is in the web navigation and reads only the latest snapshot. The Sunday email's Research section gives the per-author and paired headlines, and marks figures older than a week as the last computed.
- **Step review (DHH; counselors `agents/counselors/phase26-step2/`), all taken:**
  - The baseline is horizon-aware and frozen per forecast (§0.3), with `reference_volatility` on the proposal and the forecast, frozen like the reference close.
  - A forecast is scored only a week after its last possible session (`Forecast#window_ends_on`), so a cut is never flattered by fast hits and stops while slow expiries are open.
  - The overlap rule blocks through the planned window, not the resolved one, over every non-void forecast.
  - Mixed-author cuts (overall, setup) count one forecast per proposal, the agent's.
  - The paired cut keeps or drops a pair whole, leaves out operator forecasts made after looking (counted), and carries a head-to-head operator-less-agent difference with its interval.
  - Intervals resample by week of `starts_on`.
  - Below the floor only the counts are stored, and the floors are stored with the row.
  - An entry-day stop is ambiguous only when that day also reached the target (resolver version 2).
  - Reliability is quintiles with ties broken by id.
  - Wording says "lower is better", gives the sign of skill and the hindsight Brier, warns on the screen when the figures are stale, and the email says each author's own score is not a comparison.

**Step 3 (decision snapshots).** As planned (§0.4), on entries only:
- `Research::Features.snapshot` runs in `Proposals::Create` after the draft and before the lock. It reads final candles for the instrument and SPY through the tool cache, and `Desk` for the open-risk ratio.
- A stale, failed, or rate-limited history leaves every market feature missing with the reason, and an exception leaves the whole snapshot missing. Neither ever refuses the proposal.
- `order_proposals.features` is frozen once set, by the same trigger as the reference close and the approval quote.
- The proposal page shows each feature, or why it is missing, with the formula version and the date of the last bar.
- **Step review (DHH; counselors `agents/counselors/phase26-step3/`), all taken:**
  - **Partial bars through the cache.** `StopCollar::Candles.final` now judges today's bar by when the history was fetched, not by the clock, and only 15 minutes after the regular close. Before this, a history cached at 15:58 and read at 16:01 passed its partial bar as final. That fix also covers step 1's reference close and volatility, and the resolver.
  - **Never backfilled.** What a proposal saw when it was made (`reference_close`, `reference_on`, `reference_volatility`, `features`) is written with the row or never, so a value measured later cannot be backfilled. The approval quote stays frozen once set.
  - **The features themselves:**
    - The module is a class whose feature methods return a value or a `Missing` reason, and one feature's failure is that feature's alone.
    - A history ending more than two trading days ago is not read.
    - The ATR is `StopCollar::Candles#atr`.
    - Every value is a fraction, rounded once. Volume is the multiple less one, like the averages.
    - The snapshot stores the benchmark, the proposal's `reference_on`, and what the open-risk ratio leaves out.
    - The units are written in the module, and a spec pins every version 1 formula on a fixed tape.

**Step 4 (hypotheses).** As planned (§0.5, §0.6), with these specifics:
- `hypotheses` is frozen by a whole-row trigger less the status and decision columns, and `evidence` is frozen once set. A database check keeps `holdout_from` on or after the creation date in New York, and the model refuses a holdout before today in words.
- `order_proposals.hypothesis_id` is written with the row or never, by the same trigger as the other creation-time measures. A proposal can name only a hypothesis in `testing`, only on an entry, and only with the hypothesis's setup, which the draft adopts.
- Evidence is the closed trades with a realized R whose entry proposal named the hypothesis and was created on or after `holdout_from`, in close order. Excluded trades count and are listed in the verdict.
- The verdict covers the first `min_sample` trades:
  - n and mean R;
  - a one-sided sign-flip p-value, smoothed so it is never zero;
  - a one-sided 95% bootstrap lower bound;
  - the number of hypotheses ever tested, and the Bonferroni bar;
  - whether it clears: p at or under the bar, with mean R above zero;
  - the trade ids.

  Before the decision it is computed on the research page from rows. At the decision it is frozen into `evidence`.
- The approver writes a hypothesis or variant on `/research`, moves it to testing, accepts (only a verdict that clears), rejects, or retires, each with a reason and a `hypothesis_status_changed` audit row. The Sunday email lists hypotheses ready for a verdict.
- `propose_order` takes an optional `hypothesis_id`, and the manual form offers the hypotheses under test.
- **Step review (DHH; counselors `agents/counselors/phase26-step4/`), all taken.** It replaces some of the specifics above:
  - **The sample is fixed in advance.** It is the first `min_sample` named entries that became trades on or after the holdout, in the order proposed, so close order cannot favour fast stop-outs or fast winners. It is ready once every one of them has closed with an R, and no earlier named entry is still waiting to become a trade.
  - **An evidence trade's stop is the proposal's.** `Trade#review` refuses a different stop, so its R cannot move after the outcome. Per-trade R values are frozen in `evidence`.
  - **The test is a centred bootstrap.** It makes no symmetry assumption, which a skewed R needs, and replaces the sign-flip test. The lower bound is at the bar's own level, and clearing needs p at or under the bar and a positive lower bound, both read from the stored rounded values.
  - **The family is the hypotheses tested by the time the sample completed,** not when Decide is pressed, so the verdict is a function of rows alone. The page shows what a decision would freeze, and identical rows are cached.
  - **Retiring a ready hypothesis freezes its verdict,** so a failure is on record. Retiring one still proposed is allowed; the database check now permits it.
  - **The database freezes the decision.** Testing, decision, and evidence columns are frozen once set, and status moves follow an allow-list.
  - **A hypothesis that cannot be named is dropped, not refused.** That covers one not under test, before its holdout, on a non-entry, or with a mismatched setup. The entry goes ahead unnamed, with a `hypothesis_not_named` audit row and the reason in the tool's answer. `proposal_created` carries the hypothesis.
  - **Unlinked entries are counted.** Named entries that filled into another proposal's trade are shown as not evidence.
  - The Sunday email lists ready hypotheses by name only and computes nothing. Naming is now `reason:` throughout, and `decide!(decision:)`.

**Step 5 (decay check and costs).** As planned (§0.7, §0.8), with these specifics:
- **Costs.**
  - `Trade::Costs` runs in `Trade#recompute!` from the journal's own legs, giving `trades.slippage` per leg and `trades.gross_r`.
  - The initial entry is measured against the approval mid (bid and ask, else the mark). A stop-out is measured against the planned stop, in original-entry units after any split.
  - Each leg is tagged `comparable`, `shadow`, `not_comparable`, or `unavailable`. Gross R adds back only comparable costs.
  - `Setup#recompute_stats!` stores `gross_avg_r` with `cost_sample_size`. The Sunday email shows them after the realized figures, and the journal's trade page shows each leg's cost with its tag.
  - The draft's `min_expected_r` rule was cut at the plan review. Expected R before costs (p × reward-to-risk − (1 − p)) is a line beside each forecast on the proposal page, with the forecast's frozen baseline.
- **Decay.**
  - Entries can name an accepted hypothesis as well as one under test, so the decay check has trades to read. `DecayCheck` reads the named trades after the sample, closed with an R, in proposal order. It writes a row only from 20 trades on and only when a trade has closed since the last row: mean R and its bootstrap interval against the declared `expected_mean_r`, flagged with a suggestion when the interval's upper end is below it.
  - `Research::DecayJob` runs Saturday at 08:20. `/research` shows the latest check on each accepted hypothesis; the Sunday email shows the flagged ones.
- **Step review (DHH; counselors `agents/counselors/phase26-step5/`), all taken:**
  - **Stop costs.** A stop-out is measured against the stop that triggered (the stop order's own price, so a trailed stop is never scored against the original plan), over every fill of that order.
  - **Comparable entries.** An entry is comparable only when it was marketable (limit at or above the ask), approved on a quote that was not stale, and filled in that session. A resting limit measures the market's move, not cost.
  - **Gross R.** A trade from no proposal has no costs. Gross R needs a comparable entry, so every trade with one measured the same thing. Setups store `costed_avg_r`, the realized average over the same trades as `gross_avg_r`, so their difference is the cost.
  - **Decay check.**
    - It reads the trades proposed after the frozen sample's last trade, never one the verdict held.
    - A look is due whenever the set of trades has changed, and a same-day rerun rewrites the day's row.
    - A look below the declaration is marked `below` and flagged only on the second in a row, since every look re-examines a growing sample. A flag is a prompt to look, not a test.
    - Each row counts the named trades still open.
    - Retired hypotheses never show as decaying.
    - The row and its audit row are written in one transaction.
  - Expected R moved to `Forecast#expected_r`. `decay_summary` takes the check, and the latest check is preloaded, so nothing is counted on render.

**Step 6 (skeptic note).** As planned (§0.9), with these specifics:
- **The run.** `Research::SkepticJob` is enqueued after commit by `Proposals::Create`, for entries the rules did not reject. It makes one `AgentRun` (kind `skeptic`, `order_proposal_id`) through `Agent::Conversation` with the scheduled read-only tools and a skeptic system prompt of its own.
- **Database rules.** One non-failed skeptic run per proposal, while the one-per-kind-per-day index excludes the skeptic. The note, its risk, and its run are frozen once written.
- **The note.**
  - The model ends with "Risk: <word>", parsed into `skeptic_risk` from the fixed list, and anything else is "other".
  - The note is never emailed, and is excluded from the undelivered digest.
  - On the proposal page it is hidden, like the agent's forecast, until the operator has added theirs or chosen to look.
  - The page shows a failed run as a line, and the note's cost.
- **The tool.** `get_research_summary` is read-only and scheduled, never over MCP, so the agent that writes forecasts never reads its own calibration.
- **Cost.** The system page counts the month's skeptic notes and their share of the spend. The brief list leaves them out.
- **Step review (DHH; counselors `agents/counselors/phase26-step6/`), all taken:**
  - **Email and digest.** A capped skeptic run is never in the failure digest. A failed one is, as a missing note.
  - **Recovery and caps.**
    - A finished run whose note was never written (a worker killed between the two) is written from, not paid for again.
    - A race to start a run is caught by the unique index and ends quietly.
    - The skeptic has its own budgets (6 turns, 8 tool calls, 120,000 input tokens), no `evaluate_hypothetical_order` (it answers in share counts), and a daily cap of 25 runs that leaves a skipped run and a line.
  - **Writing the note.**
    - `Agent::SkepticNote` reads the risk line loosely (bold, punctuation, blank lines) and never leaves it in the note. A word off the list is "other", and an over-long note is cut and says so.
    - A bare risk line leaves no note, and the database requires a whole note.
    - The note and its audit are written in one transaction without touching `updated_at`.
  - **The prompts.**
    - The system prompt forbids arithmetic of the skeptic's own.
    - It gives the date and the desk's degraded reasons, and drops the memory files it never had.
    - The user prompt supplies the forecast's expected R and the setup's measured costs, so nothing has to be worked out. Free text is quoted as JSON strings, the thesis capped at 1,000 characters.
  - **The page.**
    - The skeptic panel has its own "show it first" button through the recorded reveal.
    - An operator who could not add a forecast (no target, no reference close) sees the note outright, since blindness then protects nothing.
    - A stale, capped, skipped, or noteless run each say so, and a note written after the decision says that too.
  - **The system page** counts skeptic runs and the notes they wrote.
  - **The migration's `down`** removes skeptic runs before restoring the one-per-day index.

**Step 7 (Playwright).**
- **Tests:** `e2e/research.spec.js` covers the operator's blind forecast beside the agent's, then both shown; a resolved forecast reading as scored; the research screen's calibration; and a hypothesis accepted on its verdict and another moved to testing.
- **Scenarios:** two new ones, `forecasts` and `research`.
- **Reset:** the reset lifts the freeze triggers on the frozen tables, test-only, to empty them.

## 9. Phase review (DHH; counselors in two parts, `agents/counselors/phase26-review-a/` and `-b/`; a first whole-phase run timed out)

All taken unless said otherwise. These were the seams between steps that the step reviews could not see.

- **Research never decides what is proposed.**
  - A named hypothesis no longer supplies the setup. Sizing and the rules read the setup, so a hypothesis about a setup counts an entry only when the entry names that setup itself, and is dropped with the reason otherwise.
  - `Hypothesis#refusal_for` is the one statement of the naming rule, read by the draft and by the proposal's validation.
  - The hypothesis is re-read under the lock, so one retired while the entry drafted is dropped, never refused.
- **`Proposals::Create`.**
  - A forecast's own fields (`Forecast.check_claim!`) are checked before anything else, the one forecast failure that refuses, so no halt is ever lost to it. Any other forecast failure leaves the entry unforecast, in its own savepoint, on the record.
  - The halts are re-read under the lock.
  - Only the save raises the duplicate-proposal refusal.
  - Every refusal writes `proposal_refused`.
  - A failure after commit (the alert, the skeptic's enqueue) is reported, never raised.
- **`forecastable?` is `Forecast.measurable?`,** so the page never offers a form that would refuse.
- **One candle reader.** `StopCollar::Candles.read` serves the collar (at least 30), the reference close, and the decision snapshot. The standard deviation moved to `Research::Stats`.
- **Statistics.**
  - **Decay check.** It reads the trades after the sample as a prefix in proposal order, up to the first still open, so it no longer favours fast losers. A flag needs the second look below to add at least five trades.
  - **Paired calibration.** It pairs only the same claim (session and horizon), with the overlap rule applied to every pair before maturity.
  - **Interval floor.** Intervals drawn by week need eight weeks; below that the cell says too few weeks.
  - **Baseline (version 2).** It exposes a marketable entry to the stop for the whole entry session, as the resolver does.
  - **Ended names.** A history that stops after the entry, delisted or not, gives up as a miss marked `ended_early`, never a void.
  - **Coverage.** The agent's calibration cut carries its coverage too.
  - **The verdict.**
    - Its cached result is keyed with `Research::Stats::VERSION`.
    - It says when the sample mean is below what was declared, and labels a sample under 30 as indicative.
    - Its audit row's live count is named `tests_now`, so it is never read as the bar's.
- **Costs.**
  - An entry is comparable only when approved inside the regular session and filled within 15 minutes of the approval, so a pre-market approval filled at the open books no gap as slippage.
  - Gross minus realized is slippage, not fees: the trade page says gross is still net of fees.
- **Skeptic.** A failed run is retried once and no more, and the daily cap is counted under an advisory lock.
- **Not taken.**
  - **Squashing the migrations that replaced `order_proposals_measures_frozen` in turn.** They are committed, and `structure.sql` holds the final function, which both part A reviewers checked against every existing writer and found refuses nothing. Squashing would rewrite committed history for no change in behaviour.
  - **Freezing the proposal's own levels (limit, stop, target, setup, sizing) in the database.** No path writes them after creation, and the forecasts copy them when written. This is recorded as a gap in enforcement, not a bug.
  - **The baseline computed inside the proposal's transaction.** About 30 ms; left there, since its seed is the proposal's id.
  - **The split ratio voiding a real −50% or −33% gap.** Already disclosed in §7.
