Read the requested docs and skimmed the listed code. Findings:

**Contradictions / Invariants**

1. [§0.1 / §1](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:7): the plan replaces PRD `deployment_policies` with a `risk_rules` row, while PRD §5.12 names `deployment_policies` as a data model addition.
Proposed change: “Phase 2.5 adds `deployment_policies` unless the user explicitly approves a PRD amendment to model deployment policy as a scoped, versioned `risk_rules` row.”

2. [§1](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:20): `risk_rules.scope` is added, but the active index “stays `(rule_type, setup_id)`.” That weakens the PRD requirement that allocation rules be structurally separate from trade guardrails.
Proposed change: make the unique index `(scope, rule_type, setup_id)` and split `RiskRule::TRADE_TYPES` / `BOOK_TYPES`; `Guardrails::Evaluator` must query only `scope: :trade`.

3. [§0.10](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:16): “Unattended runs stay read-only” is imprecise because the drift/tranche jobs create DB proposals. That is compatible with PRD §5.12 only if “read-only” means no Schwab/model write.
Proposed rewording: “Unattended runs remain broker-write-free and model-free: they may write audited deterministic rows and shadow proposals, but they never call Schwab order endpoints.”

4. [§0.5](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:11): allocation targets are `instrument_id` based, but current proposal drafting resolves by symbol in [app/models/proposals.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/proposals.rb:8), which erodes the CUSIP identity invariant.
Proposed design change: extend `Proposals.draft` / `Proposals::Create` to accept `instrument:` or `instrument_id:`; allocation jobs must pass the target instrument row, not re-resolve by symbol.

5. [§0.6 / §2](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:12): only `allocation_drift_checked` and target/tag audits are named. Thesis review, cash inflow, tranche, fund-flow, correlation, and status transitions need audit coverage under the Phase 2 “every logged action” invariant.
Proposed change: add explicit audit events: `thesis_review_created/decided`, `cash_inflow_detected/status_changed`, `deployment_tranche_scheduled/proposed`, `fund_flow_changed`, `correlation_checked`, and `allocation_drift_recorded`.

**Design Defects**

6. [§2](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:33): drift job vs human proposal race is not defined. `Proposals::Create` checks pending proposals before save and relies on DB uniqueness later ([create.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/proposals/create.rb:15)).
Proposed change: drift job should take an account+instrument advisory lock, skip if any pending/unresolved proposal exists on that instrument, and write `action: existing_proposal` on the drift row.

7. [§0.8 / §2](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:14): drift, immediate inflow, and tranche jobs can all propose against the same cash/target without a shared allocator.
Proposed design change: add one `Allocation::Planner` that consumes open allocation proposals/tranches/drifts as committed intent, and enforce idempotency with a source key such as `(account_id, instrument_id, side, allocation_source_type, allocation_source_id)`.

8. [§0.4](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:10): weight math can mix fresh balance equity with stale/partial position prices. Current freshness is balance-centric ([desk.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/desk.rb:114)).
Proposed rewording: “A drift run requires a fresh balance, fresh positions feed, and priced market values for every active target component; otherwise it records `unavailable` with the stale/unpriced component list.”

9. [§0.5 / §4](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:50): `rebalance` is neither current `entry?` nor `exit?`; current rules and proposal drafting branch on those predicates ([rule.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/guardrails/rule.rb:23), [proposals.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/proposals.rb:15)). This leaves halts, child stop reduction, lots, and exposure checks underspecified.
Proposed change: introduce predicates like `opens_exposure?`, `reduces_position?`, and `requires_bracket?`; rebalance buys open exposure, rebalance sells reduce position and use the exit child-action/tax-lot path.

10. [§0.4 / §1](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:21): asset-class targets have no assignment model. `instrument_tags` only covers leveraged/diversifier.
Proposed change: add authored `asset_class` on instruments or a separate classification table, audited on change, with overlap rules for instrument targets vs class targets.

11. [§0.4 / §7](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:68): delisted/unpriced targets are not handled. Instruments already carry delisting state ([instrument.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/instrument.rb:19)) and positions can be unpriced ([position.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/position.rb:48)).
Proposed change: active targets on delisted or unpriced instruments must produce `unavailable` plus a dashboard/system warning to retire or replace the target; no proposal should be created.

**Missing PRD Pieces**

12. [§3](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:44): PRD says deployment proposals render lump-sum vs staged base rates. The plan says static text is cited in the prompt, but not that it appears in Flow 2.
Proposed change: add a “Deployment context” panel to deployment proposal detail, frozen into proposal metadata at creation.

13. [§0.9 / §2](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:15): cash-drag has no persisted diagnostic row/job, while Sunday review is supposed to read data and not compute in prompt.
Proposed change: add `cash_drag_diagnostics` or make `SundayReviewJob` compute/store the diagnostic before rendering; include policy, cash percent, duration, threshold, and action.

14. [§0.3](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:9): PRD says leveraged/amplified flag. The plan only permits `leveraged`.
Proposed change: either name the tag `leveraged_amplified` or allow both `leveraged` and `amplified` with identical mechanical exclusion.

**Cut From Phase 2.5**

15. [§2](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-2.5-plan.md:36): cut storing a SPY-vs-SPY correlation row. Keep SPY as the benchmark series only; storing its self-correlation adds noise and no decision value.

No file edits were made; the workspace is read-only and this was a review-only task.
