The prior counselor run for this prompt timed out with an empty output file, so this is the review itself. It is based on the PRD, the flows doc, plan §4 and §6, the models, the two sync jobs, the Schwab activity mapper, and the schema in structure.sql.

# Step 6 design review: journal builder, setup stats, snapshots

## Critical: will produce wrong journal rows on day one

**1. Bootstrap plus link-fills double counts every holding whose entry fills are inside the sync window.** The plan text still says 60 days, but the feed job uses a 364-day lookback (app/jobs/sync/feed_job.rb:4). On the first sync, most positions will have their entry fills inside the window. The sequence is: positions sync runs, BootstrapJob creates a trade with a synthetic 40-share entry leg, activities sync runs, LinkFillsJob finds an open trade and appends the real 40-share buy as a second entry leg. The trade now shows 80 shares against a broker position of 40, and the next full sell leaves it open at 40 forever. The ordering is not even deterministic, since the tick enqueues positions and activities as independent jobs.

Fix: make the synthetic leg a reconciling plug, not a fixed entry. Its quantity is broker quantity minus the net quantity of linked fill legs, recomputed after every bootstrap and every link run, and deleted when it reaches zero. This one rule also answers "bootstrap quantity disagrees with a later broker position" and the sell-before-bootstrap race. The bootstrap job should also skip positions with zero or negative quantity and nil average price.

**2. Forward splits, stock dividends, and ACAT deliveries are classified as `transfer` and the design drops them.** The mapper returns `corporate_action` only when an activity carries two security items and `transfer` when it carries one (app/models/schwab/activity.rb:52). A 2:1 split on the same CUSIP arrives as one RECEIVE_AND_DELIVER with a single item for the 40 new shares. The design lists only cash-only transfers, so a transfer with an instrument and an open trade is silently stamped journaled with no leg. Trade quantity stays at 40, the broker says 80, and selling 80 drives running quantity to negative 40. The ratio is not on the activity. It has to be derived: (running quantity + delivered quantity) / running quantity, or reconciled against the broker position.

Related and in the same bucket:
- **Return of capital is unreachable.** A ROC arrives as DIVIDEND_OR_INTEREST with a security, which maps to `dividend`, so it will always become an income leg. Drop the basis-adjustment path for Phase 1 and treat it as income. Realized P&L is identical either way. Only basis attribution differs.
- **CUSIP succession collides with a bootstrapped trade on B.** Corporate actions post days after the position changes. The positions sync sees B, BootstrapJob opens a bootstrapped trade on B, then the succession activity tries to move A's trade to B and hits the one-open-trade-per-instrument index. Define the merge: an unreviewed bootstrapped trade on B is absorbed, and A's trade takes its place.
- **No trade-without-position reconciliation.** Bootstrap only covers positions without a trade. If A's succession activity never arrives, or a position is delivered out by ACAT, A's trade stays open with no position indefinitely. After each complete positions sync, any open trade whose instrument has no position and no unjournaled fills should be flagged needing review with a reason.
- **The activity row keeps only one instrument.** For a two-security activity, `instrument_id` is whichever item came first in the payload. LinkFills has to read both securities out of `raw`, and the design should say so.
- **Cash in lieu** for fractional shares arrives as CASH_RECEIPT or similar, which the mapper classifies as a `deposit`. That is a flow in the snapshot math, and it is wrong.

**3. Realized P&L will double-count fees or ignore them, depending on which formula gets coded.** Schwab's `netAmount` is the signed cash impact and already includes commissions and fee items. The design's formula, exits minus entries minus commissions minus fees plus income, is correct only if exits and entries are quantity times price. If any leg uses `net_amount`, fees are subtracted twice. Pick one: store `cash_amount` on every leg as the activity's `net_amount` and define realized P&L as the sum of leg cash amounts. Then add a spec and a live-data check that `net_amount` equals minus (quantity times price) minus commission minus fees for a buy fill. If the identity fails on a real fill, quarantine it rather than guess.

**4. Initial risk on "the first entry leg" is wrong for partial fills, negative for legacy holdings, and fictional for post-hoc stops.**
- A 40-share order filling as two activities of 25 and 15 gives initial risk on 25 shares, so realized R is overstated by 1.6x. Define initial quantity as all entry fills sharing the first entry's `order_id`, with a fallback of all entries before the first exit for orphans. Store `initial_quantity` explicitly.
- A bootstrapped holding reviewed with a stop above the broker average price yields negative initial risk. `Trade#realized_r_available?` only checks nonzero, so R will be computed and it will be nonsense. Initial risk at or below zero must give nil R.
- A bootstrapped trade that closes before review, then gets a stop typed in afterward, produces an R measured against a stop that never existed. Review on a closed bootstrapped trade should set setup and thesis only, and leave R nil.
- On the scale-in question: keep R denominated in initial risk. That is the standard definition and it is what expectancy per setup means. Store total risk, the sum of each entry leg's quantity times its distance to the stop at that time, as a second column for the journal browser, but do not divide by it.

**5. Snapshots lose flows on every gap and fake a drawdown.** Net flows are summed for flows with trade date on the snapshot day. Snapshots are skipped on days with no fresh balance, so a deposit that lands during a paused-sync day, or on a day where the balance was missing, is never subtracted. The next snapshot books it as return, the high-water index jumps, and every day after shows a permanent fake drawdown. This is exactly the §5.2 failure the design is supposed to prevent. Define net flows as all flows with trade date after the prior snapshot's date and up to this one. The same rule handles weekends and holidays.

Also in the snapshot math:
- **Share transfers valued at net amount** are valued at zero, since a stock ACAT carries no cash. Equity jumps by the market value with no offsetting flow. Value them at quantity times the day's price from the position, or exclude the day and flag it.
- **Withdrawal classification is by sign only.** If Schwab reports ACH_DISBURSEMENT amounts as positive, which is unverified, every withdrawal becomes a deposit and the index moves the wrong way. Classify by type first for the directional types and use sign only for ELECTRONIC_FUND and JOURNAL, quarantining a disagreement.
- **Balance choice.** "Latest balance on or before the close" can be a 15:50 balance. Prefer the latest balance on the day at or after the regular close, falling back to the day's latest, and skip the day if none.
- **Deposit timing.** The balance may include a pending ACH before the activity's trade date. Then day D books a fake gain and day D+1 a fake loss. The rebuild corrects the index only if the flow date matches the balance move. Accept trade date, write the spec, and watch the first real deposit.
- **The rebuild trigger cannot fire as written.** The activities upsert calls `update!` on a found-or-initialized row and never records which rows were new. Capture `new_record?` before the update and enqueue the rebuild from the earliest new flow date.
- **Prior equity of zero** on a newly funded account divides by zero. The first snapshot must be the first day with positive equity.

## Major: idempotency, ordering, concurrency

**6. Recompute trades from legs, never incrementally.** If the job crashes after inserting a leg and before updating the trade and stamping `journaled_at`, the rerun hits the unique leg index and the trade aggregates are stale. Wrap leg insert, trade recompute, and `journaled_at` in one transaction per activity, and make trade fields a pure function of the legs in `executed_at` order.

**7. Out-of-order arrival breaks trade boundaries.** A sell can arrive in an earlier sync than its buy, or a PENDING activity can flip to VALID later, or an activity with only a trade date sorts to midnight UTC ahead of the day's fills. Processing incrementally, the sell bootstraps a trade from the fill and closes it, then the buy opens a new one. The same-day wash of four fills becomes three trades with a bogus bootstrapped one. When a newly linked activity precedes the latest leg on that instrument, replay the instrument's fills from scratch, or at minimum flag the trade.

**8. Re-synced activities are not handled.** The upsert overwrites price, quantity, and status. A VALID to INVALID flip after journaling leaves a leg for a busted trade. A corrected price leaves a stale leg. Clear `journaled_at` and drop the leg when a journaled activity's quantity, price, or status changes on upsert. ACTIVITY_CORRECTION rows need a decision too.

**9. Bootstrap and link race on the open-trade index.** They are separate job classes with separate concurrency keys. Give both a shared `limits_concurrency` key per account, and rescue `RecordNotUnique` with a re-find.

**10. Side nil and unresolved instruments.** A fill with `positionEffect` AUTOMATIC and nil `net_amount` has no side. A fill whose instrument did not resolve has no `instrument_id`. Both must quarantine, not raise.

## Major: review path and stats

- **No "Not a trade" outcome.** The Monarch flow has Skip / Not a trade / Save. Status is open or closed only and there is no exclusion flag. Legacy holdings and dividend reinvestment buys will pollute setup stats. Add an `excluded_from_stats` boolean, set by the review form.
- **Stats recompute triggers are incomplete.** A closed trade gains a realized R only when review sets the stop, and loses it when excluded. Recompute after review and after exclusion, not only on close.
- **Define win rate** as realized R greater than zero. State what breakeven counts as.
- **Dividends after close** have no rule. Attach to the most recent closed trade on the instrument and recompute, or stamp with no leg. Say which.

## Sequences and the rows they must produce

| Sequence | Expected rows | Where the design fails |
|---|---|---|
| Buy 40 @ 50, sell 40 @ 55, stop 48 | One trade, two legs, peak 40, entry 50, exit 55, P&L 200 less fees, initial risk 80, R about 2.5 | OK if P&L uses one formula (item 3) |
| Buy 40 @ 50, buy 20 @ 52, sell 30 @ 55, sell 30 @ 54 | One trade, four legs, peak 60, entry 50.67, exit 54.5, P&L 230, initial risk 80, R 2.875, total risk 160 | Store total risk (item 4) |
| Legacy 40, sell 15 day one | One bootstrapped trade, plug leg 40, exit 15, running 25, open, needs review | Two trades if the sell links first; 65 shares if the buy is in the window (item 1) |
| 2:1 split with stop 48 on 40 @ 50 | Adjustment leg ratio 2, 80 @ 25, stop 24, initial risk unchanged | Dropped as a transfer (item 2) |
| Cash dividend mid-trade | Income leg, cash amount from net amount, P&L up, basis untouched | Dividend after close undefined |
| Reverse merger A to B in one activity | B predecessor is A, trade moved to B, adjustment leg with ratio, entry and stop rescaled | Collides with bootstrapped B, needs both securities from raw, A dangles if late (item 2) |
| Same-day wash, out of order | Two trades, two legs each | Three trades with a bogus bootstrap (item 7) |
| Partial fill 25 plus 15 on one order | One trade, two entry legs, initial quantity 40 | Initial risk on 25 shares (item 4) |

## What the EOD brief and dashboard need that is not produced

- **Day change** on the dashboard should be flow-adjusted: equity minus flows minus prior snapshot equity. Derivable, but only if the prior snapshot exists. Say what to show on a gap day.
- **Trailing-20 trend** per setup for the Sunday edge review is not in the stats columns. Either add it or defer it visibly.
- **Stopped-out flag.** Flow 4 shows planned versus actual stop. Whether the exit came from the stop child order is derivable through the exit leg's activity and its order type, but nothing records it. Add it at close time.
- **Fills recap** for the EOD should read activities journaled today, not trades created today. Both are needed and neither is named as a query.
- **Missing post-mortems** will include closed bootstrapped legacy trades unless the exclusion flag exists.

## Recommended order of fixes before writing code

1. Plug-leg bootstrap reconciled to the broker position (item 1).
2. Handle instrument-bearing transfers as adjustments with derived ratio, drop the ROC path, define the succession merge and trade-without-position sweep (item 2).
3. Sum of leg cash amounts for P&L, initial quantity from the first order, nil R for non-positive risk (items 3 and 4).
4. Flows since prior snapshot, type-first withdrawal classification, new-record detection for the rebuild trigger (item 5).
5. Transactional per-activity linking with full recompute from legs, replay on out-of-order arrival, shared concurrency key (items 6 through 9).
6. Exclusion flag and recompute triggers (review path).
