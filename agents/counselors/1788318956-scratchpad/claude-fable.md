**Verdict: not ready to commit.** The state plumbing is complete, but the auto-relist rule undoes the operator on the next sync, and the dashboard still paints a delisted row as an alarm.

**Must change before commit**

- **Auto-relist fires on a stale price.** `app/jobs/sync/positions_job.rb:23` relists whenever last price is positive, and last price is just marketValue divided by quantity. Schwab's position payload carries no price timestamp, and for a halted or delisted stock it keeps reporting the last print as marketValue. So any holding delisted while Schwab still shows a stale positive value is relisted within one sync cycle, audited as "Schwab priced it again". The spec at `spec/models/delisted_holding_spec.rb:26` proves this rather than the intended behavior: the fixture's XYZ marketValue never changed. Fix by recording the last price at delist time and relisting only when a positive price differs from it, or drop the auto-relist entirely. Add a spec that an unchanged positive price does not relist.

- **Dashboard row reads as at-risk.** `app/views/dashboard/_glance.html.erb:33` gives every non-protected row the at-risk class, so "delisted" renders in danger red. That breaks the one promise this feature makes. Add a third class with muted styling. Also gate the primary line: a delisted holding with a stale price and a still-working stop shows "x% to stop" because distance_to_stop ignores protection.

- **Prompt names ghosts.** `app/models/agent/context.rb:39` lists every delisted instrument globally, not the ones held. When Schwab eventually removes the position row, the system page can no longer relist it (it lists held positions only), and the brief keeps naming a symbol the desk no longer holds. Derive the list from dashboard rows with protection delisted, or clear delisted_at when the position disappears.

- **Tool output still carries stale numbers.** get_portfolio returns last price, market value, unrealized P&L, and distance to stop for a delisted row. Rule 1 in the system prompt tells the model every number from a tool result is usable, so it may narrate a stale P&L. Null those fields for delisted rows in `app/models/agent/tools/get_portfolio.rb:24`.

**Should change**

- `app/models/snapshot.rb:63` preloads working stops but not instruments, so the unprotected count now does one instrument query per position. Add instrument to the includes.
- Section 5 of the plan lists every protection state except delisted. Add the bullet; the section 11 paragraph alone is easy to miss.
- No Playwright scenario or e2e label for the state.

**Fine as is**

- **Authorization and CSRF.** The controller inherits the authentication before_action, and Rails 8.1 defaults leave forgery protection on for the button_to form. Single-user, so no account scoping is needed. The flash renders in the layout.
- **Journal and review flags.** Leave them. Missing setup and missing stop are about the plan, not the market. Position missing fires only when Schwab removes the row, and that is exactly when the trade needs a closing leg or an exclusion.
- **Consumers.** Dashboard sort, excluded summary, snapshot count, get_account_health, the review page label, and the EOD snapshot line all handle the state through the label table or the unprotected predicate.
- **The morning brief** will list the symbol under a "still held, no market" line and, once the tool nulls are in, should say it is delisted and skip it in the risk narrative. The email frame itself does not mention it, which is correct since the count already excludes it.
