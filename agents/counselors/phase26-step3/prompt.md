# Review request: Phase 2.6 step 3 (decision snapshots)

Review the staged change (`git diff --cached`) against `docs/phase-2.6-plan.md` (§0.4, §4 step 3, §8 step 3). Read-only: do not edit or run anything that writes.

Look for, in order:
1. **Look-ahead or bad arithmetic in `app/models/research/features.rb`:** a partial bar read; ATR, moving averages, the 63-session relative return against SPY, volume against its average; a feature computed from fewer bars than it needs; SPY misaligned with the instrument.
2. **Invariant breaks:** the snapshot able to refuse, delay, or change a proposal; a Schwab call under a lock or in a page render; the features editable after creation (check the trigger in `db/migrate/20261017120001_add_proposal_features.rb`).
3. **Anything that will make the features useless when joined to outcomes later:** missing context, ambiguous units, a version that would not change when a formula does.
4. Anything simpler that does the same.

Report findings by file and line, most severe first, each with a concrete failure scenario and the fix. Say plainly when something is fine.
