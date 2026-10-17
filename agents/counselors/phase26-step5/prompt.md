# Review request: Phase 2.6 step 5 (decay check and costs)

Review the staged change (`git diff --cached`) against `docs/phase-2.6-plan.md` (§0.7, §0.8, §4 step 5, §8 step 5). Read-only: do not edit or run anything that writes.

Look for, in order:
1. **Cost arithmetic in `app/models/trade/costs.rb`:** the entry fill against the frozen approval mid, a stop-out against the planned stop (units after a split), the tags (comparable, shadow, not comparable, unavailable), gross R, signs, quantities for partial fills or scaled exits, and anything that would double count what realized R already nets.
2. **The decay check in `app/models/decay_check.rb`:** which trades it reads (named trades after the sample, in proposal order), the 20-trade floor, the once-per-new-close rule, the interval against the declared mean, the flag, and repeated-looks false alarms.
3. **Invariant breaks:** a check changing a rule or a setup; a number on a page computed on render beyond what is cheap; a missing audit row; the newly allowed naming of an accepted hypothesis letting the verdict's sample change.
4. Anything simpler that does the same.

Report findings by file and line, most severe first, each with a concrete failure scenario and the fix. Say plainly when something is fine.
