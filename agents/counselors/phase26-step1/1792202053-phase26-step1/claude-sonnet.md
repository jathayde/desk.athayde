# Review: Phase 2.6 step 1 (forecasts and the approval quote)

I read the staged files and the plan, and ran nothing. Bash is disabled in this session, so I didn't run the specs or `bin/ci`. I traced the code by hand. The `db/structure.sql` dump does contain the function and both triggers.

## Findings, most severe first

**1. A hole in the middle of the candle list shortens the horizon and can turn into a miss.**
`app/models/forecast/resolution.rb:25,45,52`
- The entry window and the horizon are counted in candles, with no check that the candles are consecutive sessions.
- Say Schwab drops one interior day, and the dropped day held the target touch. The horizon then fills one real session early, and `horizon.size == forecast.horizon_days` returns `miss, expired`.
- Without that day the target is never seen, so a data hole becomes a recorded miss. That is the case §0.1 says must wait.
- The same hole stretches the 5-candle entry window over 6 sessions.
- **Fix:**
  - Reject any gap between consecutive candle dates that no weekend or `MarketDay` closure explains.
  - Return `open`, and let the job count it as a failed night.
  - Add a spec with a missing interior day.

**2. The job gives up too early on some forecasts and never gives up on others.**
`app/jobs/research/resolve_forecasts_job.rb:39-45`
- `failed_nights` is never reset. After a good night, `detail.merge` keeps the old count.
  - Five non-consecutive Schwab failures across a 65-session life void a forecast as `data_unavailable`.
  - The plan says "five failed nights". Decide whether that means consecutive, and reset the count on any usable night if so.
- A name whose history simply stops is never resolved.
  - Examples: an acquired or halted name that isn't flagged `delisted?`, or stale-but-present candles.
  - `Resolution` returns `open`, `no_data` is not reached, and nothing counts a night.
  - The forecast stays open forever and holds the instrument's group.
  - **Fix:** if the last candle is older than N trading days and the verdict is open, count a failed night.
- A delisted name with an empty history skips `ended`.
  - `candles_for` returns nil, so `no_data` runs and the forecast voids as `data_unavailable` after 5 nights.
  - The plan wants `ended_early` (miss, once entered) or `never_entered`. Check `ended?(instrument)` before `no_data`.

**3. A DB check violation will surface as a 500 or a tool error instead of a refusal.**
`app/models/forecast.rb:29-33` against `db/migrate/20261017100001_create_forecasts.rb:41,19`
- `record!` checks `stop < reference_close < target` in Ruby. The DB `forecasts_levels` check also requires `stop < entry` and `entry < target`, and `OrderProposal` has no validation for either.
  - Failure: an agent proposes limit 58, stop 47, target 56, with a last close of 50.
  - Ruby passes, the insert raises `ActiveRecord::CheckViolation` (a `StatementInvalid`), and it is not caught.
  - `Proposals::Create` rescues only `RecordNotUnique` and `RecordInvalid`. The tool rescues only `Proposals::Error` and `ArgumentError`. The result is a 500 or a crashed agent run, not "forecast: …".
- The same happens with `probability.round(4)` at line 35. A probability of 0.99999 or 0.00004 passes `0 < p < 1`, rounds to 1.0 or 0.0, and hits `forecasts_probability`.
- **Fix:** validate on the rounded value and add `stop < entry < target` to the Ruby checks, so both raise `ArgumentError`. Add specs for both.

**4. The blind add can be recorded wrongly.**
`app/controllers/proposals/forecasts_controller.rb:11`, `app/controllers/proposals_controller.rb:22`, `app/views/proposals/_forecasts.html.erb:16`
- The reveal leaves no server-side trace. `saw_agent_forecast` is a hidden field computed at render time and trusted on POST.
  - The operator clicks "show it", reads the number, then loads the plain URL (back button, another tab) and submits.
  - The row says `saw_agent_forecast = false` for a forecast made after seeing the agent's.
  - A hand-edited hidden field does the same.
- The server also accepts `"1"` when no agent forecast exists.
- The reveal is a GET with a side effect, so it could be prefetched.
- **Fix:**
  - Make the reveal a POST that writes an audit row, for example `agent_forecast_revealed` for that user and proposal.
  - Have `record!` derive `saw_agent_forecast` from that row.
  - Drop the param.
- The probability is also in the `forecast_recorded` audit data. I found no audit view that renders it, so it isn't visible today. Keep the audit page off the proposal flow, or drop `probability` from that data and read it from the row.

**5. A 35% one-day move voids legitimate outcomes, and 3:2 splits get past the guard.**
`app/models/forecast/resolution.rb:12,57-62`
- Real crashes and gaps over 35% (a biotech readout, a fraud) are voided as `split`, not scored as a miss. Voids sit outside Brier, so the agent's worst losses drop out of its record and calibration looks better than it is.
- A 3:2 split is a 33.3% drop, so with unadjusted history it is scored as a stop-out. The same goes for 4:3 and 5:4.
- Whether `pricehistory` is split-adjusted is still unverified (§5 of the plan).
- **Fix:**
  - Void only when the close ratio is near a split ratio (n:1, 1:n, 3:2, 2:3, …) or the reference close was restated.
  - Otherwise score the move, with a flag.
  - Add specs: a -50% crash that is not a ratio, a 3:2 split, and a move at exactly 35%.

**6. Reading a delisted name through its successor has no continuity check.**
`app/jobs/research/resolve_forecasts_job.rb:57` and `resolution.rb:39,55`
- If the successor's history doesn't contain `reference_on`, `reference` is nil and the 2% check is skipped.
- A different company at a different price scale then resolves the forecast.
- **Fix:** when the source symbol is not the forecast's own and the reference candle is absent, void as `split` or treat it as ended.

**7. The result isn't written and audited atomically.**
`app/models/forecast.rb:53-55`
- `update!` and `AuditEvent.log` run in separate statements. A crash between them leaves a resolved, frozen forecast with no `forecast_resolved` row, and the trigger forbids a redo.
- **Fix:** wrap `resolve!` in a transaction.
- A raise from one forecast also aborts the rest of that instrument's group. Rescue per forecast, not per instrument.

**8. The trigger is an opt-out list, and one check constraint doesn't do what it reads as.**
- `db/migrate/…create_forecasts.rb:46-47`
  - Any column added later is unfrozen by default. `id` and `created_at` are unfrozen today.
  - **Simpler and safer:** compare the whole row except the result columns and `updated_at`: `(to_jsonb(NEW) - ARRAY[…]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[…])`.
  - While open, the result columns can still be set freely, for example to a hit with arbitrary `detail`. Only the resolver writes them, so this is acceptable. Say so in the plan.
- `forecasts_resolution`, line 43 (`structure.sql:609`)
  - `(outcome = 'void') = (void_reason IS NOT NULL)` evaluates to NULL when `outcome` is NULL, and a NULL passes a CHECK. An open row can therefore carry a `void_reason`.
  - Use `(outcome IS NOT DISTINCT FROM 'void')`, or `outcome IS NOT NULL AND …`.
- Other bypasses (a superuser, `DISABLE TRIGGER`, `session_replication_role`) are inherent. The truncate trigger works and the specs use transactional fixtures, so it won't break the suite.

**9. Minor points.**
- `Forecast.record!` and the controller's `own` check treat any human forecast as "yours", because the unique key is `(proposal, author)`. A second approver sees "already forecast". That is fine for a single operator.
- If the draft is at 15:59:59 and `made_at` is 16:00:01, `reference_on` is a session older than `starts_on`'s predecessor. That is harmless but can leave the geometry check stale.
- The job writes `checked_through` and `detail` every night without an audit row. That matches plan §0.11, which audits only resolution and the run.

## Checked and fine

- **Look-ahead in the window:**
  - `starts_on` is correct at its boundaries (before the open → that day, at or after the open → the next day), and the spec covers 9:29 and 9:30.
  - `final` excludes today's candle when no calendar row or close time exists, so a partial bar is never read.
  - The reference day is not scored (spec line 23).
  - `jumped` reads only through the deciding candle, so a later split doesn't un-resolve a decided forecast (spec line 58).
- **Entry window and horizon:**
  - The entry index, `window[entry_at + 1, horizon_days]`, entry-day stop-only, equal-touch semantics (`<=`, `>=`), both-levels-as-stop and the open-versus-expired boundary are all correct.
  - The entry window and the horizon do have off-by-one coverage in the spec, but only at one point each.
- **Immutability in the app:** `attr_readonly(*CLAIM)` plus the trigger covers the app, the DB trigger covers raw SQL, and the only writer of the result is `resolve!`, called from the job. The row cannot be deleted or truncated.
- **No Schwab call under a lock or in a render:**
  - `ApprovalQuote.fetch` runs before the transaction (`submit.rb:19`). Every error becomes `unavailable`, so the approval never refuses for want of a quote.
  - The forecast controller's `with_lock` holds no Schwab call.
  - The page render reads only stored rows.
- **Nothing gates, sizes or places an order from a forecast.** The only coupling is that a forecast that can't be recorded refuses the proposal, which §0.2 prescribes.
- **Unattended write scope:** the job writes forecast and audit rows only. A rate limit stops the run and reports the unreached symbols, and a bad symbol is reported and skipped.
- **Audit rows exist for:**
  - `forecast_recorded`,
  - `forecast_resolved`,
  - `forecasts_checked`,
  - the quote inside `proposal_approved`.

## Specs to add in `resolution_spec.rb`

- Equal touch: `low == entry`, `low == stop`, `high == target`.
- Target gap (open above target, scored a hit).
- Entry on the 5th candle versus a touch on the 6th, which is ignored.
- A hit or stop on the last horizon day, versus expiry.
- `horizon_days = 1`.
- An interior missing candle (finding 1).
- Unsorted input.
- A weekend `starts_on`.
- A reference candle that is absent.
- A jump during the entry window and during an open horizon.
- A 35% boundary move.
- A non-ratio crash and a 3:2 split (finding 5).
- Job specs for `ended` with an empty history, for consecutive versus non-consecutive failed nights, and for a successor with no reference candle.

## Simpler option

Drop the `reveal` GET and the hidden `saw_agent_forecast` field. Record the reveal as a POST audit row and derive the flag from it (finding 4). That is less code and can't be forged.
