Found one remaining defect.

**Finding**
[app/controllers/system_controller.rb:20](/Users/jathayde/Development/Personal/desk.athayde/app/controllers/system_controller.rb:20) validates the shadow-mode confirmation before entering the locked toggle in [app/models/system_settings.rb:46](/Users/jathayde/Development/Personal/desk.athayde/app/models/system_settings.rb:46). Two concurrent `go live` posts can both pass the pre-lock check while `shadow_mode` is true; the first turns live on, the second then acquires the lock and toggles it back to shadow using the now-stale confirmation.

Proposed fix: move the confirmation check into the same `with_lock` block that flips `shadow_mode`, or add a `toggle_shadow_mode!(user:, reason:, confirmation:)` method that reloads/locks first, checks `confirmation_word`, validates reason, then updates.

Confirmed fixes:
- `RiskRule#supersede!` now locks before stale/halt checks and versions under one transaction.
- `rule_changed` audit now includes before/after `mode`.
- Preview rows are scoped through `rule.applies_to?`.
- Submitted mode is constrained with `presence_in(RiskRule.modes.keys)`.
- Preview route/form now use `GET`.

I did not run specs; the prompt requested read-only review.
