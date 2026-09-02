**Verdict:** two before-deploy items, both on the paused-week path; the rest are later. Cross-layer contracts largely agree; the disagreements below are the exceptions.

**Before deploy**

1. **Snapshot accepts an intraday balance; the tick does not.** The tick writes today's snapshot only after positions and orders synced since the close (`app/jobs/sync/tick_job.rb:29-31`). `Snapshot.record` falls back to "the day's latest balance" (`app/models/snapshot.rb:36`) and, for a new row, stamps risk from today's positions (`snapshot.rb:27`). Any rebuild reaching a day with no post-close balance (an activities catch-up with a flow dated the death day, `app/jobs/sync/activities_job.rb:32`; or any evening Schwab outage) writes a "close" row from an 11:00 equity with Sunday's risk columns, moving the high-water mark. The fallback is the wrong side; plan §6 carries the same wording and should change with it.

2. **EOD sections have no paused gate.** `fills_today`, `trades_touched_today`, and `snapshot` (`app/models/brief.rb:39-44`) read the database as fact. During a pause they yield "no fills today" and "not yet written; equity as of Wed 11:00 AM" beside a DEGRADED subject. The only counter-signal is the as-of line. Return nil when `stale?(activities)` so the template says unknown.

**Later**

3. **`window_to` read as a completeness stamp.** Sync writes it as end of the UTC day (`app/jobs/sync/feed_job.rb:17`), always in the future. The linker reads it as "activities fetched past this fill" (`app/models/journal/linker.rb:61`). On catch-up (positions before activities), Bootstrap flags `position_missing` on every trade closed during the pause and plugs every trade bought into, since the guard at `linker.rb:39` needs fetched-but-unjournaled rows that do not exist yet. Self-heals (`app/models/trade.rb:114` on close; next Bootstrap removes the plug), so the journal and review queue are wrong for up to a positions cycle after every re-auth-after-pause. Run activities before positions in CatchUp, or compare against `account.last_synced_at`.

4. **Plug price in the wrong units** (`trade.rb:72`). Quantity is divided by the cumulative ratio (pre-split), price is the broker's post-split average. A bootstrapped trade that later splits gets `avg_entry` and `realized_pnl` off by the ratio. Price should be `average_price * linked.ratio`.

5. **Stop assignment on partial runs.** Plan §2 and §5 say assignment only on a complete run; `app/jobs/sync/orders_job.rb:25` skips only on truncation. A quarantined stop (unmapped or unresolved) drops its position to `:unprotected` with the evidence only in `unmapped_values`. Either rule is defensible; pick one.

6. **Two failure rules.** Dashboard reports a failure only if nothing succeeded since (`app/models/dashboard.rb:111`); `get_account_health` reports the last failed run's error regardless (`get_account_health.rb:25`). The tool should wrap the dashboard's.

7. **Unpriced flows.** Snapshot quarantines them (`snapshot.rb:45`); `Dashboard#day_change` passes no run and counts them as zero (`dashboard.rb:70`).

8. **Plan drift.** Activities type rejection is `:failed` in code (`activities_job.rb:22`), `partial` in plan §2. Code is right.

9. **Verify:** `Agent::Run#stale?` matches the string key `"stale"` (`app/models/agent/run.rb:115`). If tool values are symbol-keyed, no run is ever degraded by a stale result.

**Token dies Wednesday 11:00 (revoke path)**

- **Token/sync:** `record_failure` sets `revoked_at` and the pause reason atomically; in-flight feeds end `skipped_token`. Tick sweeps, refreshes the calendar (fallback rows only beyond the 7-day prefetch), writes one skipped row per hour, enqueues nothing, never reaches `snapshot_due?`. Correct.
- **Snapshots:** none Wed to Fri; Monday chains from Tuesday with flows across the gap. Correct, except item 1 on catch-up.
- **Dashboard:** revoked banner, every row stale via the pause reason, equity is Wed 11:00 marked stale, feed failures suppressed. Day change reads "since Tue close" against a Wed 11:00 equity; only the stale mark says so.
- **MCP tools:** portfolio and health carry `stale: true` and the pause reason. Honest.
- **Briefs:** run DEGRADED. Context says revoked and "nothing synced since" the first skipped row, within 5 minutes of the death. As-of lines show Wed 11:00; token line shows no expiry. Morning brief is honest; EOD misleads per item 2.
- **Digest:** silent all week by design. The nag and the DEGRADED prefix are the only daily signals, which makes item 2's calm EOD the place the operator relaxes wrongly.
- **Re-auth Sunday:** pause clears, CatchUp runs, item 3 flags land for up to an hour, and item 1 fires only if a flow is dated Wednesday.
