# Review request: Phase 2.6 step 1 (forecasts and the approval quote)

Review the staged change (`git diff --cached`) against `docs/phase-2.6-plan.md` (§0.1, §0.2, §0.8, §0.11, §4 step 1, §8 step 1). Read-only: do not edit or run anything that writes.

Look for, in order:
1. **Scoring defects in `app/models/forecast/resolution.rb`:** look-ahead (a candle read that includes range from before the forecast, or a partial bar), off-by-one in the entry window or horizon, a path where a missing candle becomes a miss, split handling, and anything `spec/models/forecast/resolution_spec.rb` does not cover that it should.
2. **Immutability:** can a forecast's claim or a resolved outcome change, by the app or the database? Check the trigger in `db/migrate/20261017100001_create_forecasts.rb` and every writer.
3. **Invariant breaks:** a Schwab call under a row or advisory lock or in a page render; an unattended path that writes beyond rows; a missing audit row for a state change; a forecast able to gate, size, or place an order; the approval refusing for want of a quote.
4. **The resolver job:** rate limits, a delisted name, five failed nights, one bad symbol holding up the rest.
5. **The blind add:** can the operator see the agent's probability before adding theirs without it being recorded?
6. Anything simpler that does the same.

Report findings by file and line, most severe first, each with a concrete failure scenario and the fix. Say plainly when something is fine.
