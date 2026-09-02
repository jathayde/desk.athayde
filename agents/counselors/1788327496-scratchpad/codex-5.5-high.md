**Findings**

1. **Before commit: POST/PUT/DELETE still retry after 401.**  
   [client.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/client.rb:178) refreshes and replays every request, including non-idempotent order writes. That violates the “no blind retries” PRD unless Schwab has explicitly guaranteed a 401 can never follow an accepted write. For order writes, treat 401 as auth failure/unknown, or refresh proactively before sending.

2. **Before commit: exit stop adjustment can leave the position naked or undercovered.**  
   [place.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/submission/place.rb:13) cancels/shrinks the stop before [placing the sell](/Users/jathayde/Development/Personal/desk.athayde/app/models/submission/place.rb:14). If stop adjustment succeeds and the sell 4xx/unknowns, the proposal records failed/unknown while the old protection is already removed or reduced. If stop adjustment itself unknowns, reconciliation searches for the exit sell even though it was never sent. These need distinct outcomes and operator/protection handling.

3. **Before commit: reconcile can declare absence from incomplete evidence and can strand rows.**  
   [reconcile_job.rb](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/submission/reconcile_job.rb:14) ignores whether the fresh orders sync succeeded, was partial, quarantined records, or was discarded by concurrency. It then records `absent_at` and can fail at [line 25](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/submission/reconcile_job.rb:25). Also, [line 17](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/submission/reconcile_job.rb:17) links the order before the proposal transition; if `record_reconciled!` fails, future matcher runs exclude the only candidate. Make link + proposal transition atomic, and do not count absence after partial/quarantined sync or prior ambiguity.

4. **Before commit: protection watch reasons over stale stop assignment.**  
   [orders_job.rb](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/sync/orders_job.rb:25) runs proposal linking and [ProtectionWatch](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/sync/orders_job.rb:26) before [assign_working_stop!](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/sync/orders_job.rb:30). That can false-alert before a newly synced child stop is assigned, or miss a vanished stop until the next run. Assign stops first, then watch on reloaded positions. Also, [protection_watch.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/orders/protection_watch.rb:22) only treats `GONE` stops as “expected protection”; returned dead statuses like `CANCELED` are not covered.

The sweep and fake client behavior look aligned. Step 5 can handle UI/copy polish; the write/reconcile/protection invariants above need fixing before commit. I did not run tests; this was a static review.
