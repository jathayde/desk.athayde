# Phase 2.5 phase-level review

I read the plan (§0 and §8), PRD §5.12 and §6, and the allocation code, models, controllers and views. I had no shell, so I did not run `git log` or `git diff 748fa1f..HEAD`. I ran no specs, and I did not read the diagnostics job, the Sunday email partials, `proposals/_drift`, `proposals/_deployment` or `thesis_reviews/_deployment_ask`. A spec grep shows no spec that combines tranche, hold, untag and rejection, so the cross-step paths below are untested.

**Verdict:** two defects (1 and 2) should block calling Phase 2.5 done. The rest can follow.

## Defects, by severity

**1. A deposit ignores an open thesis review and a standing hold (blocks)**
- `planner.rb:54` excludes only instruments that are tagged right now (`discretionary?`).
- `planner.rb:82` (`propose_deployment`) checks only for a waiting proposal.
- `plan` makes both checks (`:25` for an open review, `:28` for a standing hold). `deploy` makes neither.
- The path you listed breaks: hold a leveraged instrument, untag it, then deposit. The deposit buys into it. The same happens with a review still open after the untag.
- This contradicts §8 step 3: "a review left open after the tag comes off is answered before anything mechanical" and "a hold keeps standing whether or not the instrument is still tagged".
- Fix: in `deploy_to` or `propose_deployment`, skip with a deferred result when `account.thesis_reviews.open.exists?(instrument:)`, or when `target.standing_hold("buy", before: day.date)` returns a hold.

**2. A rolled-back blocked deployment buy discards the halt it engaged (blocks, but safety is intact)**
- `planner.rb:86` raises `Rollback` when the buy is `rejected_by_rules?`.
- `Proposals::Create` → `evaluate!` (`order_proposal.rb:119`) has already run `Guardrails.engage_halts!` inside that savepoint.
- `trip_rule_halt!` (`system_settings.rb:16-25`) does `update!`, writes the audit row and queues the alert inside the same savepoint, so the rollback removes all three.
- The buy is still blocked by the rule itself, so no unsafe order results. But a daily-loss or drawdown halt that should have tripped is never recorded, and no email goes out.
- On a deployment night the planner suppresses drift buys (`planner.rb:26`), so nothing else may re-trip it.
- `Submission::Submit` already handles this with `Blocked`, which carries the report out and engages halts after the rollback.
- Fix: carry the report out of the savepoint and call `Guardrails.engage_halts!` after the rollback. Also name the blocking rules in the deferred result; today it only says "blocked by the rules" (`planner.rb:88`).

**3. A rejected deployment buy comes back the next night as a drift rebalance**
- `rejection_standing?` (`target.rb:45`) looks only at proposals whose `allocation_source` is one of the target's drift rows.
- Deployment proposals have an inflow or tranche as their source.
- Once the inflow leaves `committing`, the next 17:10 check sees the target as underweight and proposes the same buy at a new price.
- Fix: also count rejected rebalance proposals on the target's instrument whose source is a `CashInflow` or `DeploymentTranche`. Or record the standing rejection on the instrument rather than the drift row.

**4. New cash is dropped silently**
- `cash_inflow.rb:104` (`gave_up_after_nights`) and `deployment_tranche.rb:41` (`left_as_cash`) write an audit row only.
- Neither sends an alert. `desk.deployments` (`desk.rb:130`) reads `committing`, so the dashboard line disappears the moment the status becomes `done`.
- A deposit whose deployment proposals are all rejected or expired is left as `proposed`, with no re-offer.
- Five nights may also be too short for an ACH deposit to settle.
- A halt consumes the same five-night budget (the `defer!` paths at `cash_inflow.rb:102` and `deployment_tranche.rb:20-23`), so a halt of a week or more rolls or abandons a staged schedule.
- Fix:
  - Don't count nights against the budget while a halt is the reason.
  - Alert when cash is left undeployed.
  - Show "cash left undeployed" on the dashboard, in the same place as the Deploying line.

**5. An unanswered "ask" pauses all drift buys indefinitely**
- `cash_inflow.rb:19` counts `asked` as `committing`, and `planner.rb:26` then reports every buy as "buys wait while new cash is deployed".
- Nothing expires or escalates an unanswered ask. The seeded policy is `ask`, so this is the default path.
- A staged deposit of up to 52 weeks has the same effect.
- Fix: nag on an ask older than N days, and show on the dashboard that buys are paused because of the ask.

**6. A shadow approval nobody places by hand blocks the target for good**
- `occupying` (`order_proposal.rb:47`) includes `submitted`, and `awaiting_hand_placement` is `submitted` with `shadow: true` and no `broker_order_id`.
- The planner then reports "a proposal on it is already waiting" for that target indefinitely.
- §8 accepted stepping aside, not a dead end.
- Fix: age out unplaced shadow approvals after the next close with an audited `expire`, or show them on the dashboard.

**7. Going live with allocation proposals in the queue**
- Shadow mode is read at approval (`submit.rb:39`). A rebalance created in shadow becomes a real order on the first approve after "Go live", at a stale close with a plain LIMIT.
- Verify items 59 (deposit activity shape) and 60 (LIMIT with no child accepted) are open, and nothing gates on them.
- Fix: refuse `kind: rebalance` real submissions until item 60 is closed, or expire allocation proposals when shadow mode toggles. The toggle's audit row (`system_settings.rb:66`) could also list how many allocation proposals were waiting.

**8. A thesis review page can call Schwab on render**
- `thesis_reviews_controller.rb:9` calls `PriceChart.for`, which calls `Agent::MarketData.price_history` (`market_data.rb:41`). That fetches from Schwab whenever the cache is more than 5 minutes old.
- `PriceChart`'s own header says "a page never waits on Schwab".
- This is the Phase 2 pattern, also used by `proposals_controller.rb:17` and the trade pages. Thesis reviews are a new page using it, so it breaks your invariant "nothing on a page render calls Schwab".
- Fix: add a cache-only read for pages.

**9. A retired target leaves its proposals approvable**
- `retirements_controller.rb` and `retire!` (`target.rb:32`) cancel nothing: a waiting drift proposal stays approvable, and any scheduled tranche renormalises over the remaining targets.
- The review page does handle a missing target (`_drift.html.erb:23`).
- Fix: on retire, expire pending proposals sourced from the target's drift rows, audited. Or at least warn on the targets screen.

**10. Smaller contradictions and gaps**
- **Deposit sizing:** `deploy` normalises by the instrument targets only (`planner.rb:55`, `:59`). With class or tagged targets, 100% of a deposit goes into the plain instruments. The next night's drift may then propose sells to undo it. `cash_drag_diagnostic.rb:13` assumes "one minus all targets" is intended cash. Fix: either size deposits against all targets (leaving class and tagged shares as cash), or state the behaviour on the targets screen.
- **Cash drag without a band rule:** `cash_drag_diagnostic.rb:12` treats a missing `rebalance_band` as 0. The drift check treats it as unavailable (`book.rb:47`). Fix: make cash drag unavailable too.
- **Band preview:** `band_preview.rb:18` skips rows whose action is `rejected_standing`, `thesis_review` or `existing_proposal`. The band decided those rows as well. Fix: include them.
- **Unaudited changes:**
  - `ThesisReview.raise_for!` (`thesis_review.rb:37`) refreshes an open review's numbers with no audit row. `decide!` then refuses decisions against it (`:61`).
  - `DeploymentTranche#roll!` (`deployment_tranche.rb:40`) changes the next tranche's amount without recording the new amount.
- **Plan text:**
  - §0.5 says the rebalance limit is "editable on the proposal"; §8 step 2 says it is not, and there is no edit path.
  - §3 says `/allocation_targets` and an instrument page; the code uses `/allocation`.
  - PRD §5.12 still says "per-target configurable" bands and "thesis-review proposals".
- **Diagnostics:** §0.9 says correlations go through `StopCollar::Candles`; `diagnostics_job.rb:51` uses `Agent::MarketData`. Check that it has the same rate-limit handling. `price_history` re-raises `RateLimited`, which may not match §8 step 5's "ends the run with what was computed".

## Invariants

| Invariant | Result |
|---|---|
| Nothing auto-executes; no allocation path reaches an order endpoint | Holds. The planner, drift job and inflow job only call `Proposals::Create`, and a grep found no Schwab order call in allocation code. |
| Same guardrails as a human proposal | Holds, via the `opens_exposure?`, `reduces_position?` and `requires_bracket?` predicates. The only gap is item 2 (halt lost on rollback). |
| Book rules never judge an order | Holds. `Evaluator` reads trade scope only (`evaluator.rb:12`). |
| One writer for buys | Holds under the instrument lock. `settled_cash` counts only broker-side buys, so unapproved proposals do not claim cash. §8 records that. |
| Every state change audited | Mostly. The gaps are in item 10 and the rolled-back attempts in item 2. |
| No Schwab call on page render | Fails for the thesis review page (item 8). |

## What the operator will find confusing

- **Queue** (`proposals/index.html.erb:26`): every row reads "BUY n SYM @ $x". Drift buys, drift sells, tranche buys and human proposals look identical, and each deployment buy alerts separately.
  - Fix: show the origin and kind, and the source label ("week 2 of $5,000 deposited Oct 12").
- **Dashboard:** `at-risk` styling marks a target "reported" even when the reason is "buys wait while new cash is deployed". That is not a risk. The deployment line also vanishes on `done` (item 4).
- **Targets screen:** it shows the total as "Targets · X%" but never says that a deposit invests all of itself across the plain instrument targets (item 10). A class target reads "outside band" with nothing the operator can do about it.

The email text for deposit asks is correctly branched (`alert_mailer/thesis_review.text.erb:1-5`), so I'm not listing it as a defect.
