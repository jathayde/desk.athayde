# Verify on approval

Everything the app assumes about Schwab that has not been checked against the portal. Each item maps to a `# SCHWAB_SHAPE_UNVERIFIED` marker in the adapter or a note in `docs/schwab-api-contract.md`. Work through this list the day the app is Ready For Use, then record real cassettes.

## From PRD §9
1. Exact `TaxLotMethod` enum values (community: FIFO, LIFO, HIGH_COST, LOW_COST, AVERAGE_COST, SPECIFIC_LOT, LOSS_HARVESTER).
2. Order-endpoint rate limits for the app config (community: 120/min and 4000/day for writes; 120/min reads per app).

## OAuth
3. Whether `state` is echoed on the callback. The app sends it and treats a missing echo as failure.
4. Which token-endpoint `error` value and HTTP status Schwab sends for a 7-day-expired refresh token.
5. Whether the refresh grant returns a new `refresh_token` string or the same one.
6. That refreshing never extends the 7-day refresh-token window.
7. Whether a `scope` parameter is required on authorize, and accepted values.

## Accounts and balances
8. Exact wrapper nesting of `/accounts/{hash}` (`securitiesAccount`, `aggregatedBalance`) and that `hashValue` is absent from `/accounts`.
9. `instrumentId` presence per asset type; which positions arrive without a CUSIP (cash equivalents, options, sweeps).
10. `settled_cash` derivation: `cashAvailableForTrading - unsettledCash` (A) versus `cashAvailableForWithdrawal` (B), checked against the Schwab website on a day with unsettled proceeds. The app uses `min(A, B)`.
11. Whether `fields=positions` includes closed-out zero-quantity positions from the current day.
12. Fractional quantities in positions, orders, and transactions.
13. Whether `/trader/v1/userPreference` returns a per-account nickname (it also carries plaintext numbers; scrub).

## Orders
14. Orders lookback: 60 days (schwab-py) or one year (Schwabdev). Probe 61+ days.
15. Whether `status` accepts a comma list (assumed not).
16. `orderId` presence and status on an unactivated bracket child (assumed AWAITING_PARENT_ORDER).
17. Cancel/replace: new `orderId` with the old marked REPLACED, and `replacingOrderCollection` nesting.
18. Working-status set for stop detection (WORKING, ACCEPTED, QUEUED, PENDING_ACTIVATION, AWAITING_PARENT_ORDER, AWAITING_STOP_CONDITION, AWAITING_CONDITION, NEW, AWAITING_RELEASE_TIME).

## Transactions
19. Transactions lookback (60 days versus one year and 3000 rows) and whether `startDate` beyond it returns 400.
20. Whether omitting `types` returns all types, and whether `types` accepts a comma list or must be repeated.
21. `activityId` uniqueness (assumed global) and `orderId` presence on TRADE executions.
22. Sign conventions of `amount`, `cost`, and `netAmount` on buys, sells, fees, dividends, deposits, withdrawals.
23. Shapes for cash dividend, dividend reinvestment, split, reverse split, return of capital, merger, spin-off, and symbol change; whether old and new CUSIPs share one `activityId`.
24. Timestamp offsets per field: `+0000` versus `Z` versus `-04:00`.

## Market data
25. Market-hours closed-day shape (`equity.equity`, no `sessionHours`) and behavior for past dates.
26. Quotes: placement of the `errors`/`invalidSymbols` key, whether a partially invalid batch still returns 200, and the symbol maximum per call (assumed 100).
27. Price history: response for an unknown symbol (400 or 404), and `datetime` timezone for daily candles (assumed midnight Eastern).

## Platform
28. Whether `Retry-After` is sent on 429, and the 429 body (community: `errors[].status="429"`, codes 429-001 and 429-005).
29. Actual per-minute read limit, and whether it is per app, per token, or per account.
30. Claude app custom connector: static bearer header availability for this org (plan decision 0.8).

## Added by the step 4 review
31. Refresh-token rotation under a dropped connection: refresh, kill the connection mid-response, refresh again. If the second call returns `invalid_grant`, the refresh grant is not safely retriable and the client must stop retrying it.
32. Whether issuing a new token via the authorization-code grant invalidates the previous refresh token immediately.
33. Whether the individual Trader API product's single `api` scope covers order placement (Phase 2).
