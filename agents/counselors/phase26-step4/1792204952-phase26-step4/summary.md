# Run Summary

**Prompt:** file:prompt.md
**Tools:** claude-opus, claude-sonnet
**Policy:** read-only=enforced

## Results

### ✓ claude-opus

- Status: success
- Duration: 283.0s
- Word count: 1776
- Key sections:
  - Findings, most severe first
  - 1. A closed trade's R can be edited, or the trade dropped from the sample, after the outcome is known
  - 2. Judging the first `min_sample` trades by close date favours fast trades
  - 3. Retiring a hypothesis that was never tested crashes on the database check
  - 4. The decision's own columns aren't frozen once set
  - 5. Retiring after the sample fills leaves no record of the result
  - 6. The Sunday email computes the verdict, and the research page computes it twice per row
  - 7. Statistics
  - 8. Some named entries never become evidence, and there's no count of them
  - 9. A hypothesis label can refuse an entry

### ✓ claude-sonnet

- Status: success
- Duration: 156.3s
- Word count: 1495
- Key sections:
  - Findings, most severe first
  - Checked and fine
