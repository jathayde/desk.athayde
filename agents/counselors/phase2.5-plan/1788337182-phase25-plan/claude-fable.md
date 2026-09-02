**1. Where the module authors or reprices on its own**

No path reaches Schwab outside approve and shadow; §0.10 and §8 hold. Two places let the planner author or reprice without a human.

§0.5: "A rebalance carries an explicit quantity (drift notional ÷ limit price, whole shares, rounded down; fractional shares stay unverified) and no stop". The limit price has no author and no stated source. Reword: "quantity = drift notional ÷ the EOD close the drift row used, whole shares, rounded down; the limit price is that close, frozen on the drift row, shown in the Drift panel, and editable on the proposal before approve like any manual limit."

§0.6: "carries `allocation_source_type` and `allocation_source_id` (the drift row, the inflow, or the tranche), unique per `(account, instrument, side, source)`" and "skips with `action: existing_proposal` if any pending or unresolved proposal exists". A rejected proposal is resolved, and tomorrow's drift row is a new source, so the planner re-proposes the rejected trade every night at a new price. Rejection is human intent the planner never reads. Reword: "it reads every open allocation proposal, pending tranche, today's drift rows, and any rebalance rejected on the same target since drift last crossed the band, as committed intent; such a target records `action: rejected_standing` until the human clears it on the targets screen or the drift changes sign."

Smaller: §0.2 puts the per-target `drift_band` override on unversioned `allocation_targets`, while §5.12's boundary says bands are "versioned like every other rule". Version it or drop the override into the rule.

**2. The §0 decision most likely wrong for a small account**

§0.1's `min_rebalance_notional` at $100 as the churn gate, paired with §0.5's round-down. On a small book, whole shares bind before $100 does. Take $8,000 equity and a $450 ETF at a 20 percent target: one share is 5.6 points, so the position can never sit inside a 5-point band; a $300 drift clears the minimum, rounds to zero shares, and the plan has no action for that case; where it rounds to one share the buy overshoots the band on the other side. §0.8's staged tranches compound it: $600 over four weeks is $150 a week, zero shares of most targets.

Replace with: the planner computes the whole-share quantity first and proposes only if quantity ≥ 1 and the post-trade weight is nearer target than now; anything else is `reported` with `detail: sub_share`. The $100 rule becomes a floor on the rounded order value, not on drift. The effective band per target is max(rule band, one share ÷ equity), computed at drift time and shown on the targets screen. A tranche below one share of its target rolls into the next tranche instead of proposing.
