# Verify on approval

**Live probe 2026-09-01** against the approved app and a real (quiet) cash account. Items marked RESOLVED below carry the finding; the adapter was adjusted where it mattered.

Everything the app assumes about Schwab that has not been checked against the portal. Each item maps to a `# SCHWAB_SHAPE_UNVERIFIED` marker in the adapter or a note in `docs/schwab-api-contract.md`. Work through this list the day the app is Ready For Use, then record real cassettes.

## From PRD §9
1. Exact `TaxLotMethod` enum values (community: FIFO, LIFO, HIGH_COST, LOW_COST, AVERAGE_COST, SPECIFIC_LOT, LOSS_HARVESTER).
2. Order-endpoint rate limits for the app config (community: 120/min and 4000/day for writes; 120/min reads per app).

## OAuth
3. Whether `state` is echoed on the callback. The app sends it and treats a missing echo as failure.
4. Which token-endpoint `error` value and HTTP status Schwab sends for a 7-day-expired refresh token.
5. RESOLVED: the refresh grant returns the same `refresh_token` string (two consecutive refreshes, live 2026-09-01). Store whatever comes back regardless.
6. That refreshing never extends the 7-day refresh-token window.
7. Whether a `scope` parameter is required on authorize, and accepted values.

## Accounts and balances
8. Exact wrapper nesting of `/accounts/{hash}` (`securitiesAccount`, `aggregatedBalance`) and that `hashValue` is absent from `/accounts`.
9. RESOLVED (partly): `instrumentId` was absent on every position (EQUITY and COLLECTIVE_INVESTMENT); positions carry `uniformSymbol` instead. All three real positions had a CUSIP, including a delisted security whose `symbol` is its CUSIP. Cash equivalents and options still unverified.
10. `settled_cash` derivation: `cashAvailableForTrading - unsettledCash` (A) versus `cashAvailableForWithdrawal` (B), checked against the Schwab website on a day with unsettled proceeds. The app uses `min(A, B)`.
11. Whether `fields=positions` includes closed-out zero-quantity positions from the current day.
12. Fractional quantities in positions, orders, and transactions.
13. Whether `/trader/v1/userPreference` returns a per-account nickname (it also carries plaintext numbers; scrub).

## Orders
14. RESOLVED: `fromEnteredTime` 61 and 364 days back both returned 200. Lookback is at least a year; the adapter's LOOKBACK is now 364 days.
15. Whether `status` accepts a comma list (assumed not).
16. `orderId` presence and status on an unactivated bracket child (assumed AWAITING_PARENT_ORDER).
17. Cancel/replace: new `orderId` with the old marked REPLACED, and `replacingOrderCollection` nesting.
18. Working-status set for stop detection (WORKING, ACCEPTED, QUEUED, PENDING_ACTIVATION, AWAITING_PARENT_ORDER, AWAITING_STOP_CONDITION, AWAITING_CONDITION, NEW, AWAITING_RELEASE_TIME).

## Transactions
19. RESOLVED: `startDate` 364 days back returned 200. The 3000-row cap is still unverified.
20. PARTLY: omitting `types` is accepted (200). Whether it returns every type could not be checked on an account with no activity; the sync keeps one request per type.
21. `activityId` uniqueness (assumed global) and `orderId` presence on TRADE executions.
22. Sign conventions of `amount`, `cost`, and `netAmount` on buys, sells, fees, dividends, deposits, withdrawals.
23. Shapes for cash dividend, dividend reinvestment, split, reverse split, return of capital, merger, spin-off, and symbol change; whether old and new CUSIPs share one `activityId`.
24. Timestamp offsets per field: `+0000` versus `Z` versus `-04:00`.

## Market data
25. RESOLVED: closed days (Saturday, Labor Day) return `{"equity":{"equity":{"date","marketType","product":"equity","isOpen":false}}}` with no `sessionHours`, exactly as modeled. Past dates: 400 "Date cannot be more than 7 days in the past".
26. RESOLVED (placement): a batch with an unknown symbol returns 200 with top-level `errors: {invalidSymbols: [...]}` and the valid quotes; the mapper handles it. Symbol maximum still unverified. Note the asset-type vocabulary differs per endpoint: SLV is COLLECTIVE_INVESTMENT on positions, EQUITY on quotes, ETF on instruments.
27. RESOLVED: an unknown symbol returns 200 `{"symbol","empty":true,"candles":[]}`. Daily candle dates read correctly in New York (last candle 2026-08-31 on a 2026-09-01 probe).

## Platform
28. Whether `Retry-After` is sent on 429, and the 429 body (community: `errors[].status="429"`, codes 429-001 and 429-005).
29. Actual per-minute read limit, and whether it is per app, per token, or per account.
30. RESOLVED 2026-09-01: the Claude desktop app's Add custom connector dialog offers an additional request header for this account, so the bearer-only design ships. Header name `Authorization`, value `Bearer <mcp.bearer_token>` verbatim; the value cannot be edited later, so rotating the token means removing and re-adding the connector.

## Added by the step 4 review
31. PARTLY RESOLVED: two refresh grants in a row both succeeded and the refresh token did not rotate, so a retried refresh is safe. The dropped-connection variant was not exercised.
32. Whether issuing a new token via the authorization-code grant invalidates the previous refresh token immediately.
33. Whether the individual Trader API product's single `api` scope covers order placement (Phase 2).

## Added by the step 5 review
34. Whether `toEnteredTime`/`endDate` filter by timestamp or by calendar date (the app sends end of the UTC day either way).
35. Whether `/orders/{orderId}` returns orders older than the list lookback.
36. Whether a replacement order also appears top-level with its own `enteredTime`.
37. RESOLVED: `status=WORKING` with a 364-day window returned 200. First sync now backfills a year.
38. Whether `positions` is omitted entirely on an empty account versus returned as an empty array.

## Added by the live probe
40. `/marketdata/v1/instruments/{cusip}` returns 400 "Not Found" (not 404) for a CUSIP Schwab no longer knows; symbol search works for listed securities. The adapter treats both 400 and 404 as RequestError.
41. Market hours cannot be fetched more than 7 days in the past; the calendar only looks forward.
42. The asset-type vocabulary differs per endpoint (positions, quotes, instruments). `instruments.asset_type` comes from positions only.
43. RESOLVED by accident: a refresh grant with an empty Basic auth header returns 401 with no JSON body. The client now refuses to build without app credentials (`Schwab::NotConfigured`) so a configuration gap can never read as a revoked token.
44. Whether `netAmount` on a buy fill equals −(quantity × price) − commission − fees exactly (the journal's realized P&L sums leg cash amounts; a mismatch on a real fill is quarantined rather than guessed).
45. How cash-in-lieu for fractional shares arrives (CASH_RECEIPT reads as a deposit today and would distort the flow-adjusted series).
46. Whether ACH_DISBURSEMENT amounts arrive negative (the snapshot classifies directional types by type, sign only for ELECTRONIC_FUND and JOURNAL).
47. Whether the Hotwire Native user agent passes `allow_browser versions: :modern` when the iOS shell ships (Phase 2).
48. `Agent::MODEL = "claude-sonnet-5"` and its rates in `Agent::Pricing` are unverified until the first real Messages API call; a wrong alias is a FAILED brief and a wrong rate is a quiet mispricing.

## Phase 2 (order placement; settle before step 4 of docs/phase-2-plan.md)

49. The bracket strategy: `orderStrategyType` `TRIGGER` with one `childOrderStrategies` `STOP` sell, its shape, and the child's status while the parent works (read from a bracket placed by hand and ingested by the sync).
50. Whether the order POST answers 201 with the new order id in the `Location` header, and what a duplicate or rejected payload answers.
51. `taxLotMethod` enum values on the order object.
52. Order endpoint write rate limits, separate from the 120/min read figure.
53. Whether fractional quantities are accepted on an equity order.
54. The order search parameters (`fromEnteredTime`, `toEnteredTime`, `status`) and their time precision, for the reconcile matcher.
55. Whether a `TRAILING_STOP` child is accepted inside a `TRIGGER` strategy.
56. Replace-order semantics on a `TRIGGER` child (does replacing the stop keep the parent link).
57. Whether `previewOrder` exists on the individual tier, so the payload builder can be checked without an order.
58. Whether `cashAvailableForTrading` already nets working buy orders (item 10); the settled-cash rule double-subtracts until this is known.

Added by the Phase 2.5 plan (docs/phase-2.5-plan.md §6):

59. The deposit activity type and its fields on the transactions endpoint, so a cash inflow is detected and never mistaken for a dividend or a journal entry.
60. Whether a plain LIMIT order with no child (`orderStrategyType` `SINGLE`) is accepted as the payload builder shapes it, for rebalances.
61. SPY daily price history availability and the candles rate limit at the weekly volume of the correlation job.
62. A stable source for ICI weekly long-term fund flows; until then the number is entered by hand.
63. The Hotwire Native bridge contract for a signed approve confirmation (Phase 2 §10); until then the shell submits the web's typed confirmation.
