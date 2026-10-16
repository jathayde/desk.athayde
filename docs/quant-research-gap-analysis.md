# Phase 2.6, the quant research track: gap analysis (draft for review)

Sources: bodila, "How to Build 24/7 AI Trading System With GrokBot + Opus 5.5 & Fable 5.5 (Jane Street Infrastructure)" (Readwise 01m52gy7j0kvwthnzc5dg51tdn); the "Jim Simons" GrokBot by Codila (x.ai/bot/1b7YcKo0fT9hnNaKYgH5L); and the "Jane Street"-branded build prompt image that came with them. Desk's own constraints come from `docs/artifacts/investment-copilot-prd.md` and they win wherever the two disagree.

## 0. What the sources actually are

- **The article** is framing. Its seven "rules" are real quotes from Jane Street engineers (Minsky, Cho, Henry, Wilson on Signals and Threads and Dwarkesh), mapped onto six GrokBot bots: Scout, Analyst, Quant, Skeptic, Risk, Journal, plus you as PM. The six bot descriptions and the Auto-review rules did **not** import into Readwise ("Some content could not be imported"), so we have the roles but not the prompts. Execution in the article goes through an Alpaca paper account. Past Part 2, the Readwise capture runs into an unrelated wealth-preservation piece by the same author.
- **The bot** gives no system prompt, no data sources, no track record and no backtest. It only has marketing lines ("kills 99% of trading ideas as luck", "monitors your portfolio 24/7") and a "may act on your behalf" that never says which actions. There's nothing in it to reuse.
- **The image prompt** is the only real spec. Mostly it describes a research discipline: forecasts with horizons, a calibration log, pre-registered experiments, untouched holdouts, correction for multiple testing, cost-aware evaluation, and a nightly review that proposes changes but never ships them. Nothing in it is specific to Jane Street, and it tells you not to present the result as Jane Street's.

## 1. Out of scope for desk, said plainly

Desk is one Schwab **cash** account (no shorting, no margin). It trades on a days horizon, polls in minutes, and a person approves every order (PRD §3, §7). Under those constraints the following parts of the prompt aren't future work. They don't apply:

- Market making, Avellaneda-Stoikov, inventory/adverse-selection models, and order-book imbalance or depth features. Desk has no book data, can't quote both sides, and the prompt itself says "never guess live liquidity from daily candles."
- Exchange WebSocket feeds and sub-second decisions.
- Short-leg relative value and pairs. A cash account can't short. Relative value is only possible as "own the cheap one."
- REA (Reverse Engineer Anything) and AgenKit. These are tooling choices that mean nothing for a Rails app with its own review process (the counselors, DHH review, `bin/ci`).
- QuantGPT as the data warehouse. We haven't verified that it exists, what it covers or how it's licensed. If we ever need a nightly warehouse, that has to be evaluated on its own (§4, decision 4).

## 2. Mapping: what desk already has, and the gap

### The article's seven rules

| Rule | Desk today | Gap |
|---|---|---|
| 1. Ignore 99% of data (Scout) | Watchlist with triggers; the morning brief reads only held and watched symbols (`agent/prompts/system.md.erb`) | No screener, so there's no research universe beyond the watchlist. Cross-sectional ideas need one. **Decision → §4.4** |
| 2. Every trade is "what is it worth" (Analyst) | Proposal has `thesis`, `target_price`, `planned_stop` | No fair-value range or horizon, and nothing that says how likely the target is. **Gap → §3.1** |
| 3. Most ideas are bad (Quant) | Setups are named after the fact (`Setup.named` creates on first use) and stats are computed over whatever got traded | No pre-registration, holdout or variant log. **Gap → §3.2** |
| 4. Your AI will cheat (Skeptic) | The agent can't propose, size or submit in unattended runs. Every build is checked by counselors and DHH review. Guardrails are deterministic. | Before approval, no one argues *against* a proposal. **Gap → §3.5** |
| 5. Code guards the money (Risk) | `Guardrails::Evaluator`, rules as versioned data, halts, `pending_reconciliation`, approve is the only path to Schwab | Already covered. |
| 6. Humans run weird days (PM) | Approval on every order, Face ID confirm, kill switch, shadow mode on | Already covered. |
| 7. Models decay (Journal) | Trades are journaled from fills. `Setup#recompute_stats!` computes per-setup expectancy, and there's a Sunday edge review. | Nothing compares live results to an *expected* distribution, so decay can only be seen, not tested. **Gap → §3.4** |

### The image prompt's sections

| Section | Desk today | Gap / verdict |
|---|---|---|
| `<layers>` models suggest, code decides | The PRD's architecture: Rails decides, Claude proposes | Already covered. |
| `<setup>` secrets, paper first, dashboard | Rails credentials, shadow mode, dashboard | Already covered. |
| `<data>` source and time stamp on every point, block look-ahead | Quotes and history carry `fetched_at`/`stale`. History is a **5-minute cache, not stored** (`Agent::MarketData.price_history`; desk's presets stop at 1y daily, though the endpoint takes `periodType=year` up to 20 with daily frequency per `docs/schwab-api-contract.md`). | No stored, timestamped history. Any backtest is blocked on this. **→ §3.6** |
| `<features>` versioned snapshot at each decision, saved with what happened next | Proposal freezes `collar`, `sizing` and `guardrail_results` | Doesn't freeze the market state (ATR, distance from MAs, relative strength, volume vs average) or the outcome. **→ §3.3** |
| `<strategies>` public families, log every variant | Setups as free-text names | Applicable families: mean reversion, momentum (time-series; cross-sectional only across the watchlist), volatility-aware sizing (the collar's ATR is already halfway there). **→ §3.2** |
| `<decisions>` horizon, target and calibration on every prediction. Skip when stale, missing, uncalibrated, or cost > edge | Desk already skips on stale data (`balance_stale?`, `unavailable` drift) | No horizon, probability or cost-vs-edge check. **→ §3.1, §3.7** |
| `<testing>` chronological splits, costs, multiple testing, walk-forward | None | **→ §3.2, §3.6** |
| `<risk>` hard limits, reconcile, trade-only keys | Present (guardrails, reconciliation, kill switch in `SystemSettings`). The contract documents no money-movement endpoint; confirm in `verify-on-approval.md`. | Already covered. Order-rate limit = PRD Phase 3 per-day caps. |
| `<calibration>` Brier and reliability per target and regime, cut size on drift | None | **→ §3.1, §3.4** |
| `<nightly_loop>` review, propose versioned changes, nothing self-deploys | Sunday edge review proposes deactivation and a person confirms it | Already covered in shape. It needs §3.1–3.4 to have something to review. |
| `<deploy>` VPS, health checks, alerts | dokku, `system_status`, APNs alerts | Already covered. |
| `<deliverables>` daily report: P&L, drawdown, costs, calibration, rejected experiments | EOD brief, snapshots (flow-adjusted drawdown) | Add calibration and the experiment log to the Sunday email. |
| `<before_done>` "what could go wrong" | Counselors reviews | Already covered by process. |

## 3. Proposed additions, ordered by value for the effort

Each one extends something desk already has. None of them lets a model place, size or block an order.

### 3.1 Forecasts on proposals (cheapest, highest value)

Every entry proposal gets a frozen forecast: `horizon_days`, `target_price` (already a column), a `p_target_before_stop` probability, and `forecast_source` (agent / human). It goes on `order_proposals` or in a small `forecasts` table linked to the proposal and, later, the trade. When the trade closes or the horizon runs out, a job writes the outcome: hit target, hit stop, or expired, plus the realized R. `Setup#recompute_stats!` gains a Brier score and a 5-bucket reliability table next to `avg_r`, compared against a baseline (the setup's historical hit rate). This turns "a high score is not a high chance of profit" into something measured. It needs no new data source.

### 3.2 Hypotheses before setups

Add a `hypotheses` table: statement, the setup it would become, entry/exit rules as text, a declared minimum sample, the **holdout start date** (the evidence the decision is made on comes only after this), the expected R distribution (mean, stdev), and a status: `proposed → testing → accepted | rejected | retired`. Every variant is a row, rejects included. Changing one parameter makes a new row, never an edit (Cho: "one small change or six changes"). A setup can only go `active` from an accepted hypothesis. The Sunday review reports how many hypotheses were tested and how many came out positive. With n hypotheses tested, it uses a Bonferroni or Holm bar on the t-stat rather than a flat t > 2. With desk's sample sizes this will mostly say "not enough trades yet", and that's the honest answer.

### 3.3 Decision snapshots

When a proposal is created, freeze a `features` jsonb built from what Schwab daily data actually supports, each value with the time it was computed: ATR(14), close vs 20/50/200-day averages, 63-day return vs SPY, volume vs its 20-day average, days to earnings when known, and the account's open risk. The version of the feature formula is stored with it. Outcomes from §3.1 are joined onto it later. This is the training and evaluation set any later model would need, and it fills up from normal use.

### 3.4 Decay check (the missing half of Rule 7)

Once a setup has an accepted hypothesis with an expected R distribution, the Sunday review compares its live trades against it: rolling mean R vs expected, a one-sided test, and the Brier score trend from §3.1. A failed check proposes `cut_size` (a per-setup `max_risk_per_trade` override, which risk rules already support per setup) or `deactivate`. A person confirms either one, as with today's edge review.

### 3.5 Skeptic pass (advisory only)

When a proposal is created, a separate agent run gets the proposal, its features and its setup's stats, with one job: write the strongest case against the trade (stale thesis, earnings inside the horizon, the setup's sample too small, cost vs edge). The result is stored as a note shown on the proposal detail page. It's **not** a guardrail. Models don't override risk code, and they don't veto trades either. It runs under the same read-only unattended rules as the briefs.

### 3.6 Stored price history, then a small backtester (blocked, largest)

A local backtest is only honest with a stored, as-of-stamped daily history: a `daily_bars` table keyed by instrument and date, with `source` and `fetched_at`, written by a nightly job for the watchlist, holdings and SPY. The contract lists daily bars up to `periodType=year&period=20`, so a backfill may only need a new range in `Agent::MarketData::RANGES` plus a nightly job. Verify depth, adjustment for splits and dividends, and the rate limit on approval before counting on it. A licensed source is only needed if Schwab's depth or adjustments fall short (§4). Only after that comes a plain-Ruby walk-forward tester for the hypothesis rules in §3.2. It fills at the next open with a slippage assumption, uses no future bars, and reports net expectancy, max drawdown, turnover and cost sensitivity. It runs offline as a rake task and its result is written to the hypothesis row. It should be the last thing built, because §3.1–3.4 work without it and will show whether it's worth building.

### 3.7 Costs in expectancy

Schwab equity commissions are zero, but spread and slippage aren't. Freeze the bid/ask at approval on the proposal (it isn't stored today; only `limit_price` is), record the fill against both, compute realized slippage per trade, and report `avg_r` net of it. Once the forecast from §3.1 exists, a guardrail in `caution` mode can warn when the expected R after costs is below a floor. It's deterministic and a rule like any other.

## 4. For the user to decide

1. **Where this goes.** I'd treat it as a parallel research track (call it 2.6) that starts after 2.5 ships. It isn't Phase 3: the PRD's Phase 3 is auto-submit, and §3.1–3.4 are what would earn Phase 3.
2. **Who writes the forecast probability.** The agent, you, or both. Logging both shows which one is calibrated.
3. **The order to build in.** I recommend 3.1 → 3.3 → 3.2 → 3.4 → 3.7 → 3.5, with 3.6 held until the forecast log has a few months of data.
4. **Research universe and data.** Is research watchlist-only (time-series ideas only), or a fixed screened universe (say, S&P 500 members via FMP, already a named secondary in the PRD) that makes cross-sectional momentum possible? The universe decides how much history §3.6 stores. If it's from FMP, check the licensing for storing that data before anything is built.
5. **The skeptic's model and cost.** It's one extra agent run per proposal.

## 5. What could go wrong

- **Sample size is the binding constraint.** One person trading on a days horizon produces maybe tens of trades a year per setup. Calibration and decay tests will mostly say "insufficient" for a long time. That's a correct answer, but it shouldn't be dressed up as signal.
- **Forecasts made after the fact.** If the probability can be edited after approval, the calibration log means nothing. It has to freeze at creation, like `sizing`.
- **Survivorship and look-ahead in stored history.** A watchlist-only bar store leaves out the names you stopped watching. Backtests on it are biased upward.
- **The skeptic becoming a rubber stamp or a veto.** It needs to stay a note, and its hit rate should be journaled like anything else.
- **The framing in the sources.** "Jane Street rules" and "can actually make money" are marketing. Nothing here promises edge. It measures whether desk has any.
