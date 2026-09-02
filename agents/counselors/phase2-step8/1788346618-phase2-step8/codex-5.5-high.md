**Findings**

- **High:** [app/models/push.rb:10](/Users/jathayde/Development/Personal/desk.athayde/app/models/push.rb:10) memoizes one `Apnotic::Connection` per process. Solid Queue threads can share it, and a closed/stale HTTP/2 connection stays cached forever. There are also no explicit timeouts around [app/models/push/deliver.rb:21](/Users/jathayde/Development/Personal/desk.athayde/app/models/push/deliver.rb:21).  
  **Fix:** use a per-thread/per-job connection or a small synchronized pool, set APNs connect/read/write timeouts, and clear/rebuild the cached connection after transport/protocol failures. Do not retry the same notification automatically; report it handled and let the next send use a fresh connection.

- **High:** [app/models/push/deliver.rb:21](/Users/jathayde/Development/Personal/desk.athayde/app/models/push/deliver.rb:21) does not rescue APNs/network/protocol exceptions, and [app/jobs/push/deliver_job.rb:5](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/push/deliver_job.rb:5) lets them fail the job. `device.destroy!` / `AuditEvent.log` at [app/models/push/deliver.rb:25](/Users/jathayde/Development/Personal/desk.athayde/app/models/push/deliver.rb:25) can also raise.  
  **Fix:** wrap each device delivery in a rescue that `Rails.error.report(..., handled: true)` and returns `false`. For dead-token cleanup, perform audit and removal in one transaction so the “removed with audit row” invariant holds.

- **High:** [app/models/push/deliver.rb:24](/Users/jathayde/Development/Personal/desk.athayde/app/models/push/deliver.rb:24) deletes a device when `response.nil?`. That is not Apple saying the token is dead; it is a transport/no-response condition and could wipe valid devices during APNs or connection failures. It also treats `DeviceTokenNotForTopic` as dead, which can indicate bundle/topic/environment misconfiguration.  
  **Fix:** delete only for APNs’ explicit permanent-token cases, especially `410` / `Unregistered`. Keep and report nil responses and topic/config mismatches.

- **High:** [app/models/alert.rb:11](/Users/jathayde/Development/Personal/desk.athayde/app/models/alert.rb:11) leaks `proposal.broker_order_id` into the push body. The requirement allows the proposal path, but no order IDs in the push payload.  
  **Fix:** change that body to sanitized words, e.g. `At Schwab. Open the proposal for details.`, and keep details behind `routes.proposal_path(proposal)`.

- **Medium:** [app/jobs/push/deliver_job.rb:5](/Users/jathayde/Development/Personal/desk.athayde/app/jobs/push/deliver_job.rb:5) makes “no retries” implicit. If `ApplicationJob` or the adapter has a global retry policy, push failures can retry.  
  **Fix:** make push delivery non-raising for handled APNs failures, and add an explicit job-level spec proving failed APNs delivery is not retried.

**Spec Gaps**

- [spec/models/push/deliver_spec.rb:11](/Users/jathayde/Development/Personal/desk.athayde/spec/models/push/deliver_spec.rb:11) covers only `410 Unregistered`; add cases for nil response, APNs exceptions, `DeviceTokenNotForTopic`, and `BadDeviceToken`.
- No spec covers closed/stale connection recovery or thread sharing.
- No spec verifies APNs token auth comes only from Rails credentials, or that production without APNs credentials boots and sends zero pushes.
- [spec/models/push/deliver_spec.rb:39](/Users/jathayde/Development/Personal/desk.athayde/spec/models/push/deliver_spec.rb:39) does not exercise `fill_or_cancel`, so the broker order ID leak is currently untested.
- No job spec locks down “no retries” behavior.
