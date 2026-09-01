# Investment Copilot: UI Flows & Information Architecture

Companion to the PRD (§5.8). This is what the UI must do, not how it looks. Screens, flows, states, and the data each screen owns. Mobile-first where marked; everything renders on a phone, but some screens only need to be *usable* there, not optimized.

## Actors and entry points

One user. Three ways in:

1. **Push/email notification** → deep link to a specific proposal, trade, or health alert. This is the primary mobile entry.
2. **Direct visit** → dashboard.
3. **Sunday email** → re-auth link and edge review link.

## Screen inventory

| Screen | Priority surface | Purpose |
|---|---|---|
| Dashboard | Mobile + desktop | Glanceable state of the book |
| Proposal detail | **Mobile-first** | The approve/reject decision |
| Proposal queue | Mobile + desktop | List of pending/recent proposals |
| New proposal (manual) | Mobile + desktop | Human-initiated order proposal |
| Trade detail / journal entry | **Mobile-first** | Post-mortem quick entry |
| Journal browser | Desktop-first | Filter, R-distribution, history |
| Edge review | Desktop-first | Per-setup stats, deactivation |
| Risk rule editor | Desktop-only | Edit guardrail parameters |
| Watchlist | Mobile + desktop | Candidates + triggers |
| System health | Mobile + desktop | Token age, sync status, jobs, kill switch |

## Flow 1: Morning glance (mobile, read-only)

07:00 brief email → tap through → **Dashboard**.

Dashboard states (mutually exclusive banners, one at a time):
- **Healthy:** no banner.
- **Token expiring:** refresh token < 24h. Banner links to re-auth flow.
- **Token expired:** sync paused. Everything shows "as of [timestamp]" staleness marks. Re-auth is the only call to action.
- **Halted:** daily-loss or drawdown rule tripped. Banner states which rule and when it resets. New-proposal entry points disabled, exits still available.

Dashboard content: equity + day change, open positions (each: symbol, size, unrealized P&L, distance to stop as the primary number), total open risk ($ and % of equity), settled vs unsettled cash, pending proposal count (links to queue).

Design constraint: distance-to-stop is the number that matters per position, not P&L. P&L is emotional; stop distance is actionable.

## Flow 2: Review and approve a proposal (mobile-first, the core flow)

Notification: "Proposal: BUY 40 XYZ @ 51.20, stop 48.90" → **Proposal detail**.

Proposal detail sections, in order:
1. The order: side, symbol, qty, type, limit, stop, target. Computed: risk $ if stopped, % of equity, position value.
2. Thesis: the agent's (or your) one-paragraph reasoning, plus which setup it's tagged as.
3. Guardrail results: one row per rule, each pass / warn / fail with the actual numbers ("Risk per trade: 0.9% of equity — pass, limit 1.0%"). Collar shown as a range with the proposed stop plotted inside/outside it.
4. Action area (see states below).

Proposal states → action area:
- **All pass:** Approve and Reject buttons. Approve requires a deliberate confirm step (second tap on a changed button, or slide-to-confirm; your call, but not one-tap). This confirm is the moment the order goes to Schwab.
- **Warn(s) present** (e.g., wash-sale flag): approve is available but each warning must be individually acknowledged first (tap to expand and acknowledge).
- **Stop outside collar:** approve gated behind a required typed reason (logged). Show the collar bounds and where the stop sits.
- **Hard fail** (GFV, notional cap, halt active): no approve control at all. The failing rule is stated with its numbers. Only actions: reject, or edit-and-resubmit (which creates a new proposal through the same validation).
- **Approved → submitted → filled/cancelled:** read-only timeline view. Fill pushes a notification and links to the new journal row.

Reject: optional one-line reason, stored on the proposal.

## Flow 3: Manual proposal (human-initiated)

**New proposal** form: symbol → live quote loads → entry, stop, target fields.

Live feedback as the stop is typed:
- Collar computes and renders as a range with the typed stop plotted against it.
- Position size auto-computes from the risk rule (size = risk$ / (entry − stop)) and updates live.
- Settled-cash check runs against the computed position value.

Submit → same validation path and proposal detail screen as Flow 2. Human and agent proposals are identical objects downstream; the only difference is the author field.

## Flow 4: Post-trade journal entry (mobile-first, 30-second task)

Fill detected → journal row auto-created from transactions (entry/exit, R-multiple computed). EOD email lists rows missing post-mortems → tap → **Trade detail**.

Entry is deliberately minimal: one-line post-mortem text field + one binary control: "Followed the setup / Improvised." Save. Everything else on the screen is read-only computed data (setup, planned vs actual stop, R-multiple).

Rationale: if the journal entry takes more than 30 seconds on a phone, it stops happening.

## Flow 5: Sunday ritual

Sunday email contains: edge review summary, system health summary, re-auth button.

- **Re-auth:** button → Schwab OAuth (their hosted login) → callback → success screen showing new token expiry date. Failure state: retry with the error shown.
- **Edge review** screen: per-setup table (win rate, avg R, expectancy, sample size, trailing-20 trend). Setups with negative expectancy flagged. Action per setup: deactivate (confirm dialog stating the effect: agent stops proposing this setup). Reactivation same path.

## Flow 6: Risk rule editing (desktop, rare, deliberate)

List of rules with current parameters → edit one → before save, an effect preview: "Max risk 1.0% → 1.5% changes max position size at current equity from $X to $Y." Confirm to save. Every change is versioned with a timestamp (guardrail evaluations reference the rule version they ran against).

No bulk edit. No editing while a halt is active (prevents mood-driven loosening on a bad day; the halt banner says so).

## Flow 7: Watchlist

List: symbol, trigger note ("break above 52.10 on volume"), added date, current price vs trigger. Add/edit/remove. The agent reads triggers; a trigger being met surfaces in the morning brief, not as a push (v1).

## Flow 8: System health & kill switch

Token age (days:hours, with the Sunday cadence marked), last successful sync per feed, recent job failures, API spend this month. One control: **Pause system** (kill switch): stops all proposal creation and submission until unpaused. Unpause requires typed confirmation.

## Cross-cutting states

Every screen handles:
- **Stale data:** any market number older than its cache window shows a staleness mark with timestamp. Never render a price without its age being discoverable.
- **Token expired:** global banner, read-only mode for anything requiring fresh Schwab data.
- **Empty states:** pre-first-sync dashboard, empty journal, empty queue each need a designed state (the queue's empty state is the normal state most of the time).

## Notification inventory (revised: push in the iOS app for time-sensitive items, email for long-form)

Push (deep-link only, no figures in the payload): new proposal, fill/cancel, halt tripped, unprotected position, token expiring. Email: morning brief, EOD summary, Sunday ritual, job-failure digests. Original list:

- Morning brief (07:00), EOD summary (16:30), Sunday ritual
- New proposal awaiting review
- Fill / cancel on a submitted order
- Guardrail halt tripped
- Token expiring (T-24h), escalations Mon/Tue if Sunday re-auth missed
- Job failure (collapsed: one email per failure type per day)

## What's deliberately not designed

- No live-updating tickers or streaming charts. Numbers refresh on load and on Turbo-stream events (fills, sync completions). This is a decision system, not a terminal.
- No P&L celebration/loss states. The journal treats +2R and −1R rows identically.

## Reference direction: Mercury (web)

Mercury patterns that map directly onto our screens, from the Mobbin screen set:

- **Home → Dashboard.** Balance hero with a 30-day sparkline, accounts card to the right, a paired "money in / money out" block below, and a quick-action pill row under the greeting. Our mapping: equity + equity curve as the hero, positions as the side card, "open risk / settled cash" as the pair, and "pending proposals" as the first pill.
- **Transaction detail slide-over → Proposal detail.** Amount hero at top, then a vertical timeline (source → destination with timestamps), then metadata fields, then notes/attachments/comments. Our order is the same: order hero, thesis, guardrail rows where Mercury has GL code and notes, timeline once approved. On desktop the proposal opens as a right-hand panel over the queue, as Mercury does; on mobile it is the full screen.
- **Transactions table → Journal browser.** Summary strip (net change / in / out) above a dense table with Data Views, Filters, Date, Keywords, Amount as inline dropdowns, group-by rows with expand chevrons. Direct lift for journal: R this month / wins / losses strip, then trades with setup filter as the first dropdown.
- **Payment confirmation → the deliberate confirm.** Mercury puts an authorization sentence directly above a single primary button ("By clicking Schedule Payment, I authorize…"). That is our Approve pattern: a plain-language line stating exactly what will be sent to Schwab, then one primary button. Given the stakes, keep a second gesture, but model it on this rather than a modal.
- **"A similar payment has been created" callout → duplicate and warn states.** Mercury surfaces a possible duplicate inline in the form with the prior item embedded. Same component serves the wash-sale warn-acknowledge and the `submission_unknown` reconciliation notice.
- **Status pills in rows** (Pending, Failed) → proposal states in the queue and `unprotected` on positions.
- **Reimbursement approval modal** (document left, status timeline right, one cancel action) → the post-approval timeline state, with the thesis panel where the invoice preview sits.

Not lifting: Mercury's left-rail IA (we have five top-level areas, not fourteen), the multi-account structure, and the light-purple accent. Reference screens are on Mobbin under the Mercury web app.

## Reference direction, revised: Midday shell + Mercury detail

- **Midday (web) → app shell and dashboard.** Icon-only collapsed left rail (~40px) with a top search bar; dark theme; chart cards with a headline number, legend (current / previous / average), dashed average line, and a timeframe dropdown plus "Customize" at the card row's top right. Layout: one full-width primary chart, then a 2-up row of smaller chart cards. Our mapping: equity curve as the primary chart with HWM as the dashed line; the 2-up row is open risk over time and drawdown from HWM. The rail holds our five areas: dashboard, proposals, journal, watchlist, system.
- **Mercury (web) → detail panel, journal table, confirm pattern.** Unchanged from the section above: right-hand slide-over for proposal detail, transactions table for the journal, authorization-line-above-one-button for Approve, inline "similar item exists" callout for warn and reconciliation states.
- **Copilot Money (web), supplemental.** Three cards worth lifting: "Transactions to review" with its reviewed-everything empty state (our proposal queue on the dashboard), the range-chip row (1W / 1M / 3M / YTD / 1Y / ALL) on the net-worth chart, and "Next two weeks" as a dated upcoming list (our earnings/econ events touching the book).
- **Mobile supplements (iOS).** Revolut Business approval detail for the proposal screen structure; Navan's in-policy / out-of-policy idiom for pass/warn/fail rows and the override-with-reason sentence; Life Reset's Quick Add for the journal entry.

Open interaction with the earlier question: a dark shell makes "halt mutes the whole palette" a weaker signal than on a light UI; the halt banner probably has to carry the state on its own.

## Reference addendum: Origin (web)

Origin adds two things neither Midday nor Mercury has, and it surfaces a screen missing from the inventory above.

- **Benchmark overlay on the performance chart.** Legend row of portfolio vs S&P 500 vs component ETFs, each with its return, and a hover tooltip comparing "your portfolio" against the benchmark on a given date. Lift for the dashboard equity curve (portfolio vs SPY), and it doubles as the visual for the allocation module's correlation check.
- **Holding detail page.** Price chart with range chips, a "Your position" strip (balance, shares, cost basis, return, allocation), then a right-column card with News / About tabs and a stats row below. This is our **Position detail** screen, which the inventory above omits. Our version of the strip: shares, cost basis, unrealized P&L, working stop, distance to stop, this position's share of open risk. Right column tabs become Thesis (from the originating proposal) and History (journal legs for this instrument).
- **"Allocation & risk" card** with Asset allocation / Risk assessment tabs over a stacked bar: the allocation module's targets-vs-actual drift view, with the risk tab showing guardrail status.
- **"Market recap" summary card**: the morning brief rendered in-app, not only emailed.
- **"Pro view" toggle** on the holdings table: a dense-mode switch for the journal browser.
- Small-caps eyebrow section labels (PORTFOLIO, HOLDINGS, ALLOCATION & RISK) as the sectioning device across cards.

Origin ships both light and dark screens; the dark Reports screen earlier in this doc's search set is the same product, so it can inform either palette decision.

**Monarch** is not on Mobbin. Worth screenshotting directly for the board: its transactions "needs review" queue and the net worth / holdings views are the closest consumer analogues to our proposal queue and dashboard.

Screen inventory addition: **Position detail** (mobile + desktop), reached from any position row on the dashboard.

## Reference addendum: Monarch (web, John's screenshots)

Monarch resolves two open questions and contributes more directly usable components than any of the Mobbin sources.

**Resolves the collar question.** The credit-score band: a horizontal track segmented at labeled breakpoints (300 / 580 / 670 / 740 / 800 / 850) with the current value as a marker and the filled portion in a single color. That is the collar: breakpoints are the method outputs (percent floor, ATR, swing, Chandelier), the filled band is the acceptable range, the marker is the proposed stop. Horizontal track wins over the mini price axis.

**Guardrail headroom as budget bars.** Budget card rows (label, planned amount right-aligned, progress bar, spent left / remaining right in green). Direct lift for a "Risk budget" card on the dashboard: risk-per-trade used, daily loss used vs halt threshold, sector exposure vs cap, concurrent positions vs max. Remaining headroom in green; the bar goes to the warn color as it approaches the cap. This makes the guardrail engine visible before a proposal trips it.

**Review modal → orphan-fill and incomplete-journal review.** "Is this merchant recurring? There are 9 more to review": entity card with recent transactions, a few form fields, and three actions (Skip / Not recurring / Save as recurring). Ours: "Is this fill part of a setup? N more to review", recent fills for the instrument, setup dropdown and planned stop, actions Skip / Not a trade / Save. The orange top banner with "Review now" is the pending-review entry point; the nav badge count (Recurring 10) is the proposals count on the rail.

**Positions list, from the Accounts screen.** Per row: logo, name, sub-line, inline warning ("Account disconnected") where relevant, a small horizontal bar, a mini sparkline, amount, and a freshness stamp ("4 hours ago"). Ours: symbol, position size, inline "unprotected" warning, distance-to-stop bar, price sparkline, unrealized P&L, synced-at stamp. Collapsible group headers with group-level change and total serve the allocation view (positions grouped by target class).

**Benchmark comparison row, from Investments.** Four equal cards (Your Portfolio | S&P 500 | US Stocks | US Bonds), each with period return and today, radio-toggle to overlay on the chart below. Better than Origin's legend for our purpose: portfolio vs SPY, with the allocation module's "diversifier" instruments as the toggleable extras. Holdings table grouped by asset class with Weight and a period-change pill is the allocation drift table.

**Cash Flow analytics → journal analytics.** Segmented Monthly / Quarterly / Yearly, paired positive/negative bars per period with a net line and a dashed projection for the current period, then four stat tiles. Ours: winning R / losing R bars per period, expectancy line, tiles for net R, win rate, avg winner, avg loser. Skip the Sankey.

**AI-origin marker.** Monarch marks AI-generated content with a sparkle glyph next to the title (Weekly Recap, Budget, Spending). Adopt it: every agent-authored element (thesis, brief, review suggestion) carries the glyph, so human vs agent origin is legible at a glance. Ties to the origin field on proposals.

**Also worth keeping:** "Your Weekly Recap · date range" card as the in-app entry to the Sunday review; "this month vs last year" comparison line for equity vs prior period; Recurring's "in 1 day" countdown for upcoming earnings/econ events and "settles Tue".

Palette note: Monarch's near-black surfaces with slightly lighter cards, orange accent, green/red only for signed deltas, is close to where Midday sits; the two are compatible as a single direction.
