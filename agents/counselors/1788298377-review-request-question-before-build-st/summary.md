# Run Summary

**Prompt:** file:prompt.md
**Tools:** codex-5.5-high, claude-fable
**Policy:** read-only=bestEffort

## Results

### ✓ codex-5.5-high

- Status: success
- Duration: 167.2s
- Word count: 1026

### ✓ claude-fable

- Status: success
- Duration: 731.1s
- Word count: 3314
- Key sections:
  - Findings, in order of importance
  - OAuth contract
  - Endpoint contracts
  - 1. `account_numbers`
  - 2. `accounts(fields:)` and 3. `account(hash, fields:)`
  - 4. `orders(hash, from:, to:, status:)`
  - 5. `transactions(hash, from:, to:, types:)`
  - 6. `market_hours(markets:, date:)`
  - 7. `quotes(symbols)`
  - 8. `price_history(symbol, ...)`
