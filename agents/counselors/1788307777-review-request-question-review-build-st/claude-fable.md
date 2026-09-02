# Step 7 build review

Verdict: the design fixes from the previous review landed (status taxonomy, durable Skip, distance-to-stop guard, sweep filter, account scoping, prior-snapshot-by-date, secondary status lines). Three things will bite on the phone in the first week: "Not a setup trade" is undone by the next positions sync, a first-ever failed sync crashes the dashboard, and the stop validation the plan promised was written but never wired in.

## Critical

1. **Exclude and review-without-setup are undone within 15 minutes.** `app/models/trade.rb:69` calls `flag!(:missing_setup)` whenever the plug is zero and the trade has no setup or proposal. Every Phase 1 trade opened from a real buy fill has a zero plug and no proposal. So: John taps "Not a setup trade" (`exclude!` at `trade.rb:123` leaves `setup` nil), the next `Journal::BootstrapJob` calls `reconcile_plug!`, and the trade is back in the queue with `needs_review: true`. Same for Save with no setup picked, which the form allows (`trades_controller.rb:37` yields `nil`). The Playwright exclude test passes only because it excludes a bootstrapped trade with a non-zero, unchanged plug. Fix: `flag!` must no-op when `excluded_from_stats` or `journal_completed_at` is set, and the missing-setup re-flag at line 69 should fire only when the trade has never been reviewed. Add a spec: review, exclude, then run bootstrap, and assert both stay out of the queue.

2. **Dashboard 500s when a feed's first sync ever fails.** `app/models/dashboard.rb:50` evaluates `run.started_at > account.last_sync(run.feed)` before the `||`. `last_sync` is nil until a feed has one advanced-cursor run, and `TimeWithZone > nil` raises `ArgumentError`. The banner partial is rendered in every state, including `waiting_first_sync`, so a mapping error on the first real Schwab contact (the one place a failure is most likely) takes the whole dashboard down. Reorder to compare against `last_sync || Time.at(0)`, and drop the `|| run.started_at > 1.day.ago` clause: a failure older than a later success is not "the last sync failed." The `sync_failed` scenario at `app/models/playwright/scenario.rb:59` seeds the failure 5 minutes *before* the successes and only renders because of that clause.

3. **Stop validation exists as dead code.** `Trade#stop_warning` (`trade.rb:32`) is never called. `save_review` (`trades_controller.rb:38`) does `params[:planned_stop].presence&.to_d`, so "abc" becomes a stop of 0, which yields `initial_risk = quantity × avg_entry` and a plausible-looking, wrong R. A stop above entry saves silently with R blank, which is exactly what the plan said must not happen. Wire the warning into the controller as a redirect-with-alert before `review!`, reject non-numeric input, and add the missing spec for each case.

## Major

4. **The Playwright server runs jobs on a background thread.** No `queue_adapter` is set in `config/environments/test.rb`, so the server boots on the `:async` adapter. The re-auth success test triggers `SchwabToken.issue!`, which enqueues `Sync::CatchUpJob`; that runs the whole fake sync chain in a thread while the next test's `reset!` does `delete_all`. Today the following tests do not assert on numbers, so the leak is invisible. Set `config.active_job.queue_adapter = :test` as the plan states. RSpec already swaps in the test adapter per example, so nothing else changes.

5. **The dashboard can call Schwab from inside a Puma request.** `Dashboard#stale?` → `Account#sync_interval` → `MarketDay.session_open?` → `MarketDay.for(today)` (`market_day.rb:14`), which fetches whenever today's row is missing or `fallback`. On a day when the market-hours endpoint is down, every position row triggers a Schwab call plus a possible token refresh via `usable_token!`, synchronously, with `wait: false` raising into the rescue. That is the exact day you need the dashboard to load fast. Compute `in_session` once in `Dashboard#initialize` from `MarketDay.find_by(date:)` and pass it through; never fetch from a request.

6. **Query count per position row is roughly ten.** `rows` (`dashboard.rb:68`) calls `as_of_for` twice per row and neither `orders_as_of` nor `sync_interval` is memoized, so that is two `MAX(finished_at)` queries and one `MarketDay` lookup per row. `Position#protection` hits `covered_quantity` → `live_stops` (a query) on every call, and it is called from the sort, `open_risk`, `excluded_by_reason`, and four places in the view. `DashboardHelper#trade_for` adds one more per row. Memoize `protection` on the instance, memoize `orders_as_of`, and preload the open trades by instrument.

7. **Staleness judges the orders stamp against the positions cadence.** `dashboard.rb:68` passes `:positions` for the combined min stamp. In session the orders interval is 5 minutes, positions 15. A stop that is 25 minutes old reads fresh. Per plan §7 it should be `stale?(synced_at, :positions) || stale?(orders_as_of, :orders)`.

8. **"Sync paused since" is the first skipped run in history.** `dashboard.rb:30` takes the global minimum of `skipped_token` runs. After the first pause ever, every later expired banner shows that original date. Scope it to runs after the current token's `issued_at` or after the last `sync_resumed` audit.

9. **"Coming Sunday email" is computed three ways.** `_banner.html.erb:13` hardcodes `hour: 18` with `next_occurring(:sunday)`; `system_controller.rb:14` does the same with the constant; `TokenHealthJob#coming_sunday_email` handles "it is Sunday morning" correctly. On a Sunday morning the banner omits "or wait for Sunday's email" for a token tonight's email covers, and the system page warns that the token dies before an email that is seven days out. Promote the job's method to `SchwabToken.next_sunday_email` and use it everywhere.

10. **The no-accounts state lies.** `Dashboard#state` returns `:no_trading_account` when there are zero accounts at all, and the view says "Accounts have synced but none is enabled." After Connect, before `Sync::AccountsJob` finishes or after it fails, that is false. Add a `:waiting_for_accounts` state when `Account.none?`.

11. **Trade detail shows a later holding's stop as a closed trade's actual stop.** `trades/show.html.erb:7` falls through to `@position&.stop_price` for any closed trade that was not stopped out. The position belongs to whatever is open on that instrument now. For closed trades not stopped out, render "not hit" instead.

12. **Open bootstrapped trades collect a stop that can never produce an R.** `initial_risk_for` returns nil whenever a plug exists (`trade.rb:185`), and `total_risk_for` excludes the plug. The review form for an open legacy holding still shows the stop field with copy implying a stop yields R. Say "legacy holding: the stop is recorded, R stays blank until the entry is known."

13. **Duplicate setup name is a 500.** `Setup.create!` at `trades_controller.rb:37` raises on the uniqueness validation. Use `find_or_create_by!`, case-insensitively.

14. **Skip and "Not a setup trade" are adjacent, unpadded text buttons.** `review.html.erb:20` and `.link-button` in the stylesheet give them no tap target on a 390px screen, and exclude is one-way with no copy saying so. Give Skip a real button, move exclude below a line with "cannot be undone in Phase 1."

## Minor and missing specs

- **"1 trade need review"** at `dashboard/show.html.erb:45`. The request spec enshrines the bug. Pluralize the verb.
- **The review form asks the wrong question for four of six reasons.** `position_missing` and `corporate_action` get "Is this part of a setup?" and Save clears the flag without the user addressing the reason. At least explain the reason in the callout with what Save means.
- **The apple-touch-icon is an SVG** (`layouts/application.html.erb:15`). iOS ignores it, so the home-screen icon is a screenshot. Ship a PNG.
- **`Trade#unrealized_pnl(position)`** at `trade.rb:38` is unused and duplicates `Position#unrealized_pnl`. Delete it.
- **IRA equity line** promised in plan §7 is not rendered anywhere.
- **System feeds show only the latest run**, not last success plus latest status, and "pause since" is absent. `@failed_runs.size` counts a `limit(20)` relation.
- **Resume when not halted** still audits `manual_halt_cleared` with a nil reason. Guard on `manual_halt?`.
- **`bin/setup` never runs `npm ci` or `npx playwright install chromium`**, so `bin/ci` on a fresh checkout fails at the last step.
- **Scenario realism:** `populate` writes a snapshot for `MarketDay.today - 1`, which is a Sunday on Mondays; the `unprotected` scenario nulls the FK while the WORKING stop stays in `orders`; `review_queue` trades have no positions, which the bootstrap job would have flagged `position_missing`.
- **`hello_controller.js`** is still registered. Harmless under Hotwire Native, but it is the only JS shipping and it does nothing.
- **Brakeman** may flag the interpolated `Arel.sql` in `Trade.review_queue` under `--exit-on-warn`. Verify before commit.

Specs missing or too weak:

- Exclude then bootstrap, review-without-setup then bootstrap (item 1).
- First-feed failure with `last_sync` nil (item 2).
- Stop above entry, non-numeric stop, blank stop, duplicate setup name (items 3 and 13).
- `orders_as_of` older than `synced_at` driving the row stamp, and the orders-cadence staleness rule (item 7).
- `sync_paused_since` after a second pause episode (item 8).
- `secondary_statuses` for `:sync_paused` and `:calendar_fallback`; neither has any spec anywhere.
- Waiting-first-sync and no-positions empty states, "unavailable" cash, the `excluded_by_reason` copy, and the closed-legacy review path ignoring the stop.
- `review.html.erb` is never rendered in RSpec; only its POST is tested.
- The dashboard request spec asserts banner copy is present but never that the other banners are absent, so precedence is unverified at the view level.
- The Sunday-morning case for the banner's "or wait for Sunday's email" and the system page's warning (item 9).
