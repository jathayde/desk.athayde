# Review request: Phase 2.6 step 4 (hypotheses)

Review the staged change (`git diff --cached`) against `docs/phase-2.6-plan.md` (§0.5, §0.6, §4 step 4, §8 step 4). Read-only: do not edit or run anything that writes.

Look for, in order:
1. **Ways to tune the evidence after the fact:** a hypothesis edited, backdated, or its evidence chosen after outcomes are known; a trade moved in or out after its R is known; the verdict recomputed after it was frozen; the family count (tests) gamed, for example by retiring before testing, or by writing many variants without testing them.
2. **Statistical defects in `Hypothesis#compute_verdict` and `Research::Stats.sign_flip_p_value` / `bootstrap_lower_bound`:** the null, the sidedness, the smoothing, the Bonferroni bar, the "clears" rule, the sample (first min_sample by close), excluded and open trades, ties in closed_at.
3. **Invariant breaks:** a hypothesis gating a setup or an order; a missing audit row; a decision without the approver; a Schwab call on render; the research page doing anything too slow to render.
4. Anything simpler that does the same.

Report findings by file and line, most severe first, each with a concrete failure scenario and the fix. Say plainly when something is fine.
