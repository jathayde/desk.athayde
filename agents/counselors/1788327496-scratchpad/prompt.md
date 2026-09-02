# Review Request

## Question
Review Phase 2 step 4 of Investment Copilot (uncommitted on top of commit a92fa37; `git status --porcelain` lists the files): the real client path behind the shadow branch. Order writes on the Schwab client (one attempt, never retried, the id from the Location header, a success without one is unknown), the fake broker's placed orders served by its next orders call, Submission::Place (the exit's stop cancel or shrink first, then the order, every outcome named), the reconcile job (quiet period, fresh orders sync, one match links, two stay with the operator, absence believed only when a second look ten minutes later agrees), the submitting sweep, the protection watch and the two alert mails. Under 700 words.

## Files
@app/models/schwab/client.rb @app/models/schwab/fake_client.rb @app/models/schwab/order_payload.rb @app/models/submission/submit.rb @app/models/submission/place.rb @app/models/submission/matcher.rb @app/models/submission/sweep.rb @app/jobs/submission/reconcile_job.rb @app/models/orders/proposal_link.rb @app/models/orders/protection_watch.rb @app/mailers/alert_mailer.rb @app/views/alert_mailer/ @app/models/order_proposal.rb @app/jobs/sync/tick_job.rb @app/jobs/sync/orders_job.rb
Specs: @spec/models/schwab/client_spec.rb (the "order writes" group at the end) @spec/models/submission/place_spec.rb @spec/jobs/submission/reconcile_job_spec.rb @spec/models/submission/sweep_spec.rb @spec/models/orders/protection_watch_spec.rb @spec/models/submission/submit_spec.rb
Design: @docs/phase-2-plan.md §0.5 to §0.7, §5; @docs/phase-2-state-table.md; PRD §5.1 (idempotency) and §5.4.2 in @docs/artifacts/investment-copilot-prd.md.

## Instructions
Independent and critical. Trace every path from the approve gesture to Schwab and back: can any of them send the order twice, lose the id, or leave a row where nothing will ever move it? Is the 401 refresh-and-retry safe for a POST? Does the exit's stop action leave a position naked or double-covered on any failure order? Can the reconcile job link the wrong order, link twice, or declare "not placed" too early (clock, windows, the sync's own quarantine)? Does the sweep pick the right outcome for a shadow row versus a real row? Is the protection watch honest about "should be protected"? Say what must change before commit versus at step 5.
