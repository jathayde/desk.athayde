# Review request: Phase 2.6 step 2 (calibration)

Review the staged change (`git diff --cached`) against `docs/phase-2.6-plan.md` (§0.3, §3, §4 step 2, §8 step 2). Read-only: do not edit or run anything that writes.

Look for, in order:
1. **Statistical defects in `app/models/research/calibration.rb` and `app/models/research/stats.rb`:** the geometry baseline (driftless probability of target before stop from the entry, in log prices); the paired bootstrap of the Brier difference; the Wilson interval; the reliability buckets (quantile, at least 10, near-equal sizes); the overlap rule (one forecast per author and name per window); the paired cut; anything that flatters a forecaster or biases the score (voids, ambiguous days, selection).
2. **Invariant breaks:** anything computed on a page render or in a prompt; a missing audit row; a number shown below its floor.
3. **The screen and the email:** does each say plainly what a figure means, and say "not enough" where it should? Stale figures presented as current?
4. Anything simpler that does the same.

Report findings by file and line, most severe first, each with a concrete failure scenario and the fix. Say plainly when something is fine.
