# Phase 2.6 review, part B: statistical coherence, load, and what the plan promised

Each step of Phase 2.6 was reviewed alone (`docs/phase-2.6-plan.md` §8 records the changes). This review is for the seams. Read-only: do not edit or run anything that writes. Stay within these files; do not read the whole diff:
docs/phase-2.6-plan.md, app/models/forecast.rb, app/models/forecast/resolution.rb, app/models/research/baseline.rb, app/models/research/calibration.rb, app/models/research/stats.rb, app/models/hypothesis.rb, app/models/decay_check.rb, app/models/trade/costs.rb, app/jobs/research/*.rb, config/recurring.yml.

1. **Coherence:** do the forecast scoring rule, the frozen baseline (which must follow the same rules), calibration's maturity and overlap rules, the hypothesis sample, the decay check's reading of the frozen sample, and the costs agree with one another? Find a case where two of them disagree in a way that would mislead.
2. **Load and cost:** what runs per proposal, per night, per Saturday, and per page render, and the skeptic's spend at the daily cap.
3. **Plan against build:** what §0–§7 promise that the build does not do, or does differently without §8 saying so.

Report findings by file and line, most severe first, each with a concrete failure scenario and the fix. Under 1,200 words. Say plainly when something is fine.
