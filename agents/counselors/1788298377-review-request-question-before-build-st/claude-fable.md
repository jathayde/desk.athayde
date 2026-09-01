I have what I need. Everything below comes from schwab-py (source and docs), Schwabdev (source), the sudowealth TypeScript client's Zod schemas, the schwab-client-js reference, the R packages, and QuantConnect. The api-evangelist OpenAPI files are confirmed skeletal (four-field balances, no transaction schema) and should not be used for shapes at all.

# Findings, in order of importance

1. **Plaintext account numbers arrive in the body of every Trader API response**, not only from `/accounts/accountNumbers`. `securitiesAccount.accountNumber`, `order.accountNumber` (as an integer), and `transaction.accountNumber` are all plaintext. The plan stores `raw` jsonb on positions, balances, orders, and transactions and records cassettes. Unless the client scrubs these keys before anything else sees the body, the constraint "never store plaintext account numbers" is violated on the first sync. Scrub in `Schwab::Client`, not in the mappers, so cassettes, `raw`, and logs are all covered.
2. **`settledCash` is not a Schwab field.** The cash-account `currentBalances` block has `cashAvailableForTrading`, `cashAvailableForWithdrawal`, `unsettledCash`, `totalCash`, `cashBalance`. Two candidate derivations disagree in edge cases; store all five raw and derive conservatively (below).
3. **A GTC stop entered more than one lookback window ago is unreachable through the orders list.** `fromEnteredTime` and `toEnteredTime` must both be set, and the window is capped. The plan's `status=WORKING` daily pull does not escape the window. Add `order(hash, order_id)` to the interface and re-fetch known working stops by id, or positions will be falsely flagged `unprotected`.
4. **Three date formats on the way in, three on the way out.** Orders and transactions take `yyyy-MM-dd'T'HH:mm:ss.SSSZ`, market hours takes `YYYY-MM-DD`, price history takes epoch milliseconds. Responses use `+0000` offsets without a colon (orders, transactions), epoch ms (quotes, candles), and `-04:00` offsets (market hours). Build one `Schwab::Time` helper and spec all six forms.
5. **The account hash is sensitive and appears in every path.** The plan logs method and path. Log the path template with the hash replaced, or the cassette scrubbing rule is contradicted by the log file.
6. **Bracket children are nested, not listed.** The orders list returns parent orders with children inside `childOrderStrategies` and replacements inside `replacingOrderCollection`, each a full order with its own `orderId`. The sync must flatten recursively and set `parent_order_id` while walking.
7. **The rate limiter is per-process but two processes call Schwab.** Puma serves MCP `get_quotes` and `get_price_history` while the Solid Queue worker syncs. Two independent 120/min buckets is 240/min. Use a shared counter (a Postgres row under `SELECT ... FOR UPDATE`, or Solid Cache) or split the budget.

# OAuth contract

| Item | Value | Confidence |
|---|---|---|
| Authorize URL | `GET https://api.schwabapi.com/v1/oauth/authorize?client_id={app_key}&redirect_uri={callback}` | verified across schwab-py, Schwabdev |
| Extra authorize params | `response_type=code` and `state` are sent by schwab-py (authlib) and echoed back; Schwabdev omits both and works | UNVERIFIED that `state` is echoed; send it and verify it, treat a missing echo as failure |
| Callback | `https://desk.athayde.com/schwab/callback?code=...&session=...`; `code` ends in `@` after one URL-decode (`%40`). Rails `params[:code]` is already decoded once. Do not decode again | verified (Schwabdev, community) |
| Token endpoint | `POST https://api.schwabapi.com/v1/oauth/token` | verified |
| Headers | `Authorization: Basic base64("#{app_key}:#{app_secret}")`, `Content-Type: application/x-www-form-urlencoded` | verified |
| Code grant body | `grant_type=authorization_code&code={code}&redirect_uri={callback}` | verified |
| Refresh grant body | `grant_type=refresh_token&refresh_token={token}` (sudowealth also adds `client_id`; unnecessary) | verified |
| Token response | `{"expires_in":1800,"token_type":"Bearer","scope":"api","refresh_token":"...","access_token":"...","id_token":"<JWT>"}` | verified; do not persist `id_token` |
| Access token lifetime | 30 minutes; expired tokens are rejected, not grace-periodded | verified |
| Refresh token lifetime | 7 days from the authorization-code grant. Refreshing does NOT extend it. schwab-py warns it can expire "sooner or later" than 7 days | verified by all sources; the one blog claiming otherwise is wrong |
| Refresh response | Returns a `refresh_token` field; community reports it is the same string. Store whatever comes back, never move `refresh_expires_at` | UNVERIFIED whether the string ever changes |
| Expired or bad refresh token | HTTP 400 or 401 from the token endpoint with `error` of `invalid_client`, `invalid_grant`, `refresh_token_authentication_error`, or `unsupported_token_type` | UNVERIFIED which one Schwab actually sends for the 7-day case; treat all four as "re-auth required" |
| API call with expired access token | 401 | verified |

Send the refresh at 25 minutes as planned. On a token-endpoint 4xx, do not back off and retry; that is an auth failure and the pause path.

# Endpoint contracts

Base URLs are `https://api.schwabapi.com/trader/v1` and `https://api.schwabapi.com/marketdata/v1`. Every call sends `Authorization: Bearer {access_token}` and `Accept: application/json`. All list responses are bare JSON arrays or objects, no envelope.

**Error envelope.** Schwab's spec uses JSON:API style: `{"errors":[{"id":"<uuid>","status":"400","title":"...","detail":"...","source":{...}}]}`. The token endpoint uses `{"error":"...","error_description":"..."}`. Gateway 401s and 5xxs can be non-JSON. The error parser must tolerate all three. UNVERIFIED as a whole.

## 1. `account_numbers`

`GET /trader/v1/accounts/accountNumbers`. No params.

```json
[{"accountNumber":"12345678","hashValue":"9313A0737VVVV6C0B13DDCDF6962015FC0"}]
```

Return only the hash values from the client. Drop the numbers before returning.

## 2. `accounts(fields:)` and 3. `account(hash, fields:)`

`GET /trader/v1/accounts?fields=positions` and `GET /trader/v1/accounts/{hash}?fields=positions`. Balances come by default; `fields=positions` adds positions. The only documented `fields` value is `positions`.

`/accounts` returns an array with no `hashValue`, so linking each element to its hash requires the plaintext `accountNumber`. Do not do that join. Call `/accounts/{hash}` once per hash instead; it costs two requests.

Response (per account):

```
{
  "securitiesAccount": {
    "type": "CASH" | "MARGIN",
    "accountNumber": "<PLAINTEXT, scrub>",
    "roundTrips", "isDayTrader", "isClosingOnlyRestricted", "pfcbFlag",
    "positions": [ {
      "shortQuantity", "longQuantity",            // floats, fractional possible
      "settledLongQuantity", "settledShortQuantity",
      "averagePrice", "averageLongPrice", "taxLotAverageLongPrice",
      "marketValue", "currentDayProfitLoss", "currentDayProfitLossPercentage",
      "currentDayCost", "longOpenProfitLoss", "previousSessionLongQuantity",
      "instrument": {
        "assetType": EQUITY|OPTION|MUTUAL_FUND|CASH_EQUIVALENT|FIXED_INCOME|INDEX|CURRENCY|COLLECTIVE_INVESTMENT|FUTURE|FOREX|PRODUCT,
        "cusip",        // optional
        "symbol",
        "description",  // optional
        "instrumentId", // optional integer
        "netChange",
        "type"          // CASH_EQUIVALENT only: SWEEP_VEHICLE|SAVINGS|MONEY_MARKET_FUND|UNKNOWN
      }
    } ],
    "initialBalances": { ...start of day... },
    "currentBalances": { ...intraday... },
    "projectedBalances": { "cashAvailableForTrading", "cashAvailableForWithdrawal" }
  },
  "aggregatedBalance": { "currentLiquidationValue", "liquidationValue" }
}
```

Cash-account `currentBalances` fields: `cashAvailableForTrading`, `cashAvailableForWithdrawal`, `cashCall`, `longNonMarginableMarketValue`, `totalCash`, `cashDebitCallValue`, `unsettledCash`, `accruedInterest`, `cashBalance`, `cashReceipts`, `longOptionMarketValue`, `liquidationValue`, `longMarketValue`, `moneyMarketFund`, `savings`, `shortMarketValue`, `pendingDeposits`, `mutualFundValue`, `bondValue`, `shortOptionMarketValue`.

Balance mapping for the plan's `balances` row:

- `equity` = `currentBalances.liquidationValue`
- `cash_available_for_trading` = `currentBalances.cashAvailableForTrading`
- `unsettled_cash` = `currentBalances.unsettledCash`
- `settled_cash` (derived, UNVERIFIED): two readings. Reading A: `cashAvailableForTrading` already includes unsettled proceeds in a cash account, so settled = `cashAvailableForTrading - unsettledCash`. Reading B: `cashAvailableForWithdrawal` is the settled figure. Conservative: `min(A, B)` when both are present, else whichever exists. Guardrail 4 in Phase 2 reads this column, so the derivation must be a single named method with a spec per reading.
- `buying_power`: not a cash-account field; leave nil for CASH, use `currentBalances.buyingPower` for MARGIN.

Note the accounts API says `EQUITY` for ETFs; the quotes API says `ETF`. Instrument `asset_type` must come from the Trader API only, or symbol+asset_type fallback matching breaks.

## 4. `orders(hash, from:, to:, status:)`

`GET /trader/v1/accounts/{hash}/orders?fromEnteredTime=...&toEnteredTime=...&maxResults=3000&status=WORKING`

- `fromEnteredTime`, `toEnteredTime`: both required together, format `yyyy-MM-dd'T'HH:mm:ss.SSSZ`, e.g. `2026-08-01T00:00:00.000Z`. Send UTC with `.000Z`.
- `maxResults`: default and maximum 3000.
- `status`: one value from the enum below. Not a list. UNVERIFIED whether a comma list is accepted; assume not.

Response is an array of orders. Fields Phase 1 needs:

```
{
  "orderId": 1004055538123,          // int64, store as bigint or string
  "accountNumber": 12345678,         // PLAINTEXT integer, scrub
  "status": <enum>, "statusDescription",
  "orderType": MARKET|LIMIT|STOP|STOP_LIMIT|TRAILING_STOP|TRAILING_STOP_LIMIT|MARKET_ON_CLOSE|LIMIT_ON_CLOSE|CABINET|NON_MARKETABLE|EXERCISE|NET_DEBIT|NET_CREDIT|NET_ZERO|UNKNOWN,
  "session": NORMAL|AM|PM|SEAMLESS,
  "duration": DAY|GOOD_TILL_CANCEL|FILL_OR_KILL|IMMEDIATE_OR_CANCEL|END_OF_WEEK|END_OF_MONTH|NEXT_END_OF_MONTH|UNKNOWN,
  "orderStrategyType": SINGLE|OCO|TRIGGER|CANCEL|RECALL|PAIR|FLATTEN|TWO_DAY_SWAP|BLAST_ALL,
  "complexOrderStrategyType": NONE|...,
  "quantity", "filledQuantity", "remainingQuantity",   // numbers
  "price",                 // limit price, number in responses (string when placing)
  "stopPrice", "stopType": STANDARD|BID|ASK|LAST|MARK, "activationPrice",
  "taxLotMethod": FIFO|LIFO|HIGH_COST|LOW_COST|AVERAGE_COST|SPECIFIC_LOT|LOSS_HARVESTER,
  "enteredTime": "2026-08-14T13:31:02+0000", "closeTime", "cancelTime", "releaseTime",
  "cancelable", "editable", "tag",
  "orderLegCollection": [ {
    "legId", "orderLegType": EQUITY|OPTION|...,
    "instruction": BUY|SELL|BUY_TO_COVER|SELL_SHORT|BUY_TO_OPEN|BUY_TO_CLOSE|SELL_TO_OPEN|SELL_TO_CLOSE|EXCHANGE|SELL_SHORT_EXEMPT,
    "positionEffect": OPENING|CLOSING|AUTOMATIC,
    "quantity", "quantityType": ALL_SHARES|DOLLARS|SHARES,
    "instrument": { same shape as the positions instrument }
  } ],
  "orderActivityCollection": [ {
    "activityType": EXECUTION|ORDER_ACTION, "executionType": "FILL",
    "quantity", "orderRemainingQuantity",
    "executionLegs": [ { "legId", "price", "quantity", "mismarkedQuantity", "instrumentId", "time" } ]
  } ],
  "childOrderStrategies": [ <full order objects, recursive> ],
  "replacingOrderCollection": [ <full order objects> ]
}
```

Status enum: `AWAITING_PARENT_ORDER, AWAITING_CONDITION, AWAITING_STOP_CONDITION, AWAITING_MANUAL_REVIEW, ACCEPTED, AWAITING_UR_OUT, PENDING_ACTIVATION, QUEUED, WORKING, REJECTED, PENDING_CANCEL, CANCELED, PENDING_REPLACE, REPLACED, FILLED, EXPIRED, NEW, AWAITING_RELEASE_TIME, PENDING_ACKNOWLEDGEMENT, PENDING_RECALL, UNKNOWN`. Note `CANCELED` with one L. The plan's working set should be `WORKING, ACCEPTED, QUEUED, PENDING_ACTIVATION, AWAITING_PARENT_ORDER, AWAITING_STOP_CONDITION, AWAITING_CONDITION, NEW, AWAITING_RELEASE_TIME`; a bracket child sits in `AWAITING_PARENT_ORDER` until the parent fills. UNVERIFIED that Schwab assigns `orderId` to a child before activation.

Add: `GET /trader/v1/accounts/{hash}/orders/{orderId}` as `order(hash, order_id)`. Same shape, single object.

## 5. `transactions(hash, from:, to:, types:)`

`GET /trader/v1/accounts/{hash}/transactions?startDate=...&endDate=...&types=TRADE&symbol=...`

- `startDate`, `endDate`: both required together, same `.SSSZ` format. The tradetally bug report shows the bounds are inclusive and a same-day query needs `endDate` at `23:59:59.000Z`.
- `types`: one value from `TRADE, RECEIVE_AND_DELIVER, DIVIDEND_OR_INTEREST, ACH_RECEIPT, ACH_DISBURSEMENT, CASH_RECEIPT, CASH_DISBURSEMENT, ELECTRONIC_FUND, WIRE_OUT, WIRE_IN, JOURNAL, MEMORANDUM, MARGIN_CALL, MONEY_MARKET, SMA_ADJUSTMENT`. schwab-py sends one value; UNVERIFIED whether omitting it returns all types (Schwabdev treats it as optional). The sync needs everything, so either omit or loop the types it cares about (TRADE, RECEIVE_AND_DELIVER, DIVIDEND_OR_INTEREST, ELECTRONIC_FUND, ACH_RECEIPT, ACH_DISBURSEMENT, WIRE_IN, WIRE_OUT, JOURNAL, CASH_RECEIPT, CASH_DISBURSEMENT).
- `symbol`: optional filter.

Response is an array:

```
{
  "activityId": 95012345678,          // int64, unique per activity, the upsert key
  "time": "2026-08-14T13:31:02+0000",
  "user": { "cdDomainId", "login", "type", "userId", "systemUserName", "firstName", "lastName", "brokerRepCode" },  // drop
  "description",
  "accountNumber": "<PLAINTEXT, scrub>",
  "type": <TransactionType enum above>,
  "status": VALID|INVALID|PENDING|UNKNOWN,
  "subAccount": CASH|MARGIN|SHORT|DIV|INCOME|UNKNOWN,
  "tradeDate": "2026-08-14T00:00:00+0000",
  "settlementDate": "2026-08-15T00:00:00+0000",
  "positionId", "orderId",            // orderId present on TRADE executions, absent otherwise
  "netAmount": -1523.45,              // signed cash impact
  "activityType": EXECUTION|ORDER_ACTION|TRANSFER|ACTIVITY_CORRECTION|UNKNOWN,
  "transferItems": [
    { "instrument": { "assetType":"EQUITY","cusip":"...","symbol":"...","instrumentId":123 },
      "amount": 10, "cost": -1520.00, "price": 152.00, "positionEffect": OPENING|CLOSING|AUTOMATIC|UNKNOWN },
    { "instrument": { "assetType":"CURRENCY","symbol":"CURRENCY_USD" }, "amount": -0.03, "cost": ..., "feeType": SEC_FEE },
    { "instrument": { "assetType":"CURRENCY","symbol":"CURRENCY_USD" }, "amount": -0.02, "feeType": TAF_FEE }
  ]
}
```

feeType enum: `COMMISSION, SEC_FEE, STR_FEE, R_FEE, CDSC_FEE, OPT_REG_FEE, ADDITIONAL_FEE, MISCELLANEOUS_FEE, FUTURES_EXCHANGE_FEE, LOW_PROCEEDS_COMMISSION, BASE_CHARGE, GENERAL_CHARGE, GST_FEE, TAF_FEE, INDEX_OPTION_FEE, UNKNOWN`.

The security item is the one without `feeType` whose instrument is not `CURRENCY`. `amount` on it is share quantity; `amount` on currency items is dollars. Sign conventions on `amount` and `cost` (negative for buys?) are UNVERIFIED. The mapper should derive side from `positionEffect` plus the sign of `netAmount`, and fees as the sum of `feeType` items, never from `cost` alone. Dividend, split, return-of-capital, and merger shapes are entirely UNVERIFIED; `RECEIVE_AND_DELIVER` is the type for splits and CUSIP successions, and whether old and new CUSIPs share one `activityId` is unknown.

## 6. `market_hours(markets:, date:)`

`GET /marketdata/v1/markets?markets=equity,option&date=2026-09-08`. `markets` is a comma list of `equity, option, bond, future, forex` (lowercase). `date` is `YYYY-MM-DD`, valid from today to one year out; one date per call. Past dates: behavior UNVERIFIED, assume rejected or today.

Response on an open day:

```json
{"equity":{"EQ":{"date":"2026-09-08","marketType":"EQUITY","exchange":"NULL","category":"NULL",
  "product":"EQ","productName":"equity","isOpen":true,
  "sessionHours":{
    "preMarket":[{"start":"2026-09-08T07:00:00-04:00","end":"2026-09-08T09:30:00-04:00"}],
    "regularMarket":[{"start":"2026-09-08T09:30:00-04:00","end":"2026-09-08T16:00:00-04:00"}],
    "postMarket":[{"start":"2026-09-08T16:00:00-04:00","end":"2026-09-08T20:00:00-04:00"}]}}}}
```

On a closed day the product key changes from `EQ` to `equity`, `sessionHours` is absent, and `isOpen` is false. This is carried over from the TD Ameritrade behavior and is UNVERIFIED for Schwab, but sudowealth models `sessionHours` as optional for the same reason. The mapper must take the first value under `equity` regardless of key, and treat missing `sessionHours` as closed. Each session is an array of intervals; take min start and max end. Early closes show up as a shorter `regularMarket` interval.

## 7. `quotes(symbols)`

`GET /marketdata/v1/quotes?symbols=AAPL,MSFT&fields=quote,reference&indicative=false`. Symbols are comma-joined and must be URL-encoded (option symbols contain spaces; futures contain `/`). `fields` values: `quote, fundamental, extended, reference, regular, all`. No documented symbol maximum; 100 works in community reports. Chunk at 100. UNVERIFIED.

Response is an object keyed by symbol. Fields to map:

```
"AAPL": {
  "assetMainType": EQUITY|ETF|OPTION|MUTUAL_FUND|BOND|INDEX|FUTURE|FUTURE_OPTION|FOREX,
  "assetSubType": COMMON_STOCK|PREFERRED_STOCK|ADR|ETF|...,
  "quoteType": "NBBO", "realtime": true, "ssid": 1973757747, "symbol": "AAPL",
  "reference": { "cusip", "description", "exchange", "exchangeName", "isHardToBorrow", "isShortable", "htbRate" },
  "quote": { "52WeekHigh","52WeekLow","askPrice","askSize","askTime","bidPrice","bidSize","bidTime",
             "closePrice","highPrice","lastPrice","lastSize","lowPrice","mark","markChange","markPercentChange",
             "netChange","netPercentChange","openPrice","postMarketChange","quoteTime","securityStatus",
             "totalVolume","tradeTime","volatility" },
  "regular": { "regularMarketLastPrice","regularMarketLastSize","regularMarketNetChange","regularMarketPercentChange","regularMarketTradeTime" },
  "extended": { ... }, "fundamental": { ... }
}
```

`quoteTime` and `tradeTime` are epoch milliseconds. Unknown symbols do not fail the request; they come back under a top-level `errors` key (`{"errors":{"invalidSymbols":["XYZ"]}}`) in the same 200 response. The mapper must skip the `errors` key when iterating and report the invalid list. Exact placement UNVERIFIED. The `regular` block field names are the `regularMarket*` prefixed form; the sudowealth schema uses unprefixed names, so accept both.

## 8. `price_history(symbol, ...)`

`GET /marketdata/v1/pricehistory?symbol=AAPL&periodType=year&period=1&frequencyType=daily&frequency=1&needExtendedHoursData=false&needPreviousClose=true`, optionally `startDate` and `endDate` as epoch milliseconds (which override `period`).

Valid combinations: `periodType=day` allows `period` 1,2,3,4,5,10 and `frequencyType=minute` with `frequency` 1,5,10,15,30. `periodType=month` allows `period` 1,2,3,6 and `frequencyType` daily or weekly. `periodType=year` allows 1,2,3,5,10,15,20 and daily, weekly, monthly. `periodType=ytd` allows 1 and daily or weekly. Minute data goes back about 48 days; daily goes back decades.

```json
{"candles":[{"open":141.7,"high":143.64,"low":139.72,"close":140.71,"volume":29117421,"datetime":1730700000000}],
 "symbol":"AMD","empty":false,"previousClose":142.10,"previousCloseDate":1730613600000}
```

Daily candle `datetime` is midnight Eastern expressed in UTC ms, so convert in `America/New_York` or the date is off by one. `empty: true` with no candles for a valid symbol with no data; unknown symbols return 400 or 404 (UNVERIFIED). For the collar engine, ask for `periodType=month&period=3&frequencyType=daily` and `needPreviousClose=true`.

**Instrument lookup, add to the interface.** `GET /marketdata/v1/instruments?symbol=AAPL&projection=symbol-search` and `GET /marketdata/v1/instruments/{cusip}` return `{"instruments":[{"cusip","symbol","description","exchange","assetType"}]}`. This is the path for resolving a position or transaction that arrives without a CUSIP. Leading zeros in CUSIPs must be preserved.

# Limits and disagreements

| Limit | Reading 1 | Reading 2 | Use |
|---|---|---|---|
| Orders window | 60 days (schwab-py, R defaults) | 1 year (Schwabdev, quoting the portal spec) | 60 days; make it one constant and probe 61+ on approval |
| Transactions window | 60 days (schwab-py) | 1 year and 3000 rows max (Schwabdev) | 60 days; same constant |
| Read rate limit | 120 requests/min per app, all APIs (community consensus; portal-gated) | none | 120/min shared across processes, UNVERIFIED |
| Order write limit | 120/min and 4000/day (QuantConnect) | none | Phase 2; record now |
| 429 body | `errors[].status="429"` with codes 429-001 (rate) and 429-005 (burst) | none | UNVERIFIED; do not parse the code, back off 60s when `Retry-After` is absent |
| `Retry-After` on 429 | not documented anywhere | none | UNVERIFIED; backoff must not depend on it |
| Quotes symbols per call | undocumented; 100+ works | 300 (streaming recommendation, not REST) | chunk at 100 |
| `maxResults` | default 3000 | none | send explicitly |
| Market hours date | today to +1 year, one date per call | none | verified |

# Copy into `docs/verify-on-approval.md`

Everything marked UNVERIFIED above, plus:

- Which token-endpoint `error` value Schwab sends for a 7-day-expired refresh token, and the HTTP status.
- Whether the refresh grant returns a new `refresh_token` string or the same one.
- Whether `state` is echoed on the callback.
- `settledCash` derivation: A, B, or neither, checked against the Schwab website on a day with unsettled proceeds.
- Whether `fields=positions` on `/accounts/{hash}` includes closed-out zero-quantity positions from today.
- `orderId` presence and status on an unactivated bracket child.
- Whether `status` on the orders list accepts a comma list.
- Whether omitting `types` on transactions returns all types.
- Sign conventions of `amount`, `cost`, `netAmount` on buys, sells, fees, dividends, deposits.
- Shapes for cash dividend, split, reverse split, return of capital, merger, spin-off, symbol change. Whether old and new CUSIPs share one `activityId`.
- `+0000` versus `Z` versus `-04:00` in each response timestamp field.
- Closed-day market-hours shape (`equity.equity`, no `sessionHours`).
- Quotes `errors` placement and whether a partially invalid batch still returns 200.
- Price history response for an unknown symbol; `datetime` timezone for daily candles.
- Whether `Retry-After` is sent, and the 429 body.
- Actual per-minute limit, and whether it is per app, per token, or per account.
- Fractional quantities in positions, orders, and transactions.
- Whether `/trader/v1/userPreference` returns a per-account `nickName` usable for the dashboard label (it also carries plaintext numbers, so scrub).

# Adapter design critique

**Put the FakeClient below the mappers, not above them.** If `Schwab::FakeClient` returns mapped structs, seeds and Playwright never exercise the mapping code, which is where every shape assumption lives. Have both clients return scrubbed raw hashes with the same shape and run both through the same mappers. The fixtures the FakeClient serves are then also the VCR-shaped fixtures for specs, one set of `# SCHWAB_SHAPE_UNVERIFIED` payloads instead of two.

**Return typed values, not hashes, from the mappers.** `Data.define` structs per feed (`Schwab::Position`, `Schwab::Order`, ...) with a `raw` member carrying the scrubbed hash for the jsonb column. Jobs then never touch a Schwab key, which is the isolation the kickoff asks for and it is testable: a spec can assert no job file contains a camelCase Schwab field name.

**Interface changes.** Add `order(hash, order_id)`, `instrument(symbol_or_cusip)`, and optionally `user_preferences`. Have `account_numbers` return hashes only. Have `orders` and `transactions` take `from:`/`to:` as `Time` and do the formatting inside; callers should never build a Schwab date string. Add `Schwab::Client#authorize_url(state:)`, `#exchange_code(code)`, `#refresh(refresh_token)` on the same object so the FakeClient can script auth too.

**Error taxonomy.** One base `Schwab::Error` carrying `status`, `scrubbed_body`, `request_id` (the `errors[].id` when present), and `attempts`. Subclasses callers must be able to rescue separately:

- `Schwab::AuthError` for API 401 after one refresh-and-retry; `Schwab::ReauthRequired < AuthError` for any token-endpoint 4xx. The refresh job pauses on the second, retries later on transient errors.
- `Schwab::RateLimited` with `retry_after`, raised only after the retry budget is spent.
- `Schwab::ServerError` for 5xx after retries.
- `Schwab::RequestError` for 400, 403, 404: never retried, the caller's params are wrong. A 400 on `startDate` is how the 60-day cap will announce itself.
- `Schwab::TransportError` for timeouts and connection failures on GETs.
- `Schwab::UnknownOutcome` for the same failures on non-idempotent calls. Phase 2 needs this class to exist and to be impossible to confuse with the previous one, so define it now and have the client pick by HTTP method.
- `Schwab::MappingError` raised by mappers on a missing required field, rescued per record by the sync job.

**Retry policy corrections.** Retry only GETs and the refresh grant. Do not retry 4xx. Cap `Retry-After` at 60 seconds and fall back to 1, 4, 16 seconds with jitter when it is absent. The 401 refresh-and-retry is one extra attempt outside the backoff budget. Log the path template (`/accounts/{hash}/orders`) plus a hash fingerprint, not the hash.

**Shared rate limiter.** A `schwab_rate_limit` row with a window start and count, updated under `FOR UPDATE`, or a Solid Cache counter. Budget 100/min to leave headroom for the refresh job and MCP calls.

**Numbers and times.** Parse every money and quantity value with `BigDecimal(value.to_s)`; JSON floats into `decimal(18,4)` columns through Float will drift. Accept `price` as either number or string. For timestamps, use one helper that handles `+0000`, `Z`, `-04:00`, and epoch ms; `Time.iso8601` rejects the colon-less offset on some Ruby versions, so spec it.

**Mappers must not crash sync.** Instrument identity: CUSIP, then `instrumentId`, then symbol plus asset type with `needs_review`, then a call to `instrument(symbol)` as last resort, and options and cash equivalents will often have no CUSIP at all. Unknown enum values: store the raw string in `sub_type` or `raw`, map to `unknown`, and count it on the `sync_runs` row (`unmapped_values` jsonb) rather than raising. Do not use Rails `enum` on columns fed by Schwab strings, since assignment of an unknown value raises; use a string column with a validated allowlist and an explicit `unknown` fallback. Per-record rescue in the sync job with a `partial` outcome on `sync_runs` (the plan has only succeeded/failed).

**FakeClient scenarios Playwright and seeds need.** Scripted per call through the `/playwright/scenarios/:name` route: re-auth success (fake authorize page redirects to `/schwab/callback?code=FAKE%40&state=...`), re-auth failure (`invalid_grant`), refresh expired (`ReauthRequired`), rate limited then success, server error then success, transport timeout, empty account, position removed between two syncs, order with nested bracket child, transaction with missing CUSIP, unknown enum value, closed market day, quotes batch with one invalid symbol, and the four dashboard banner states. Each scenario is a named fixture set plus an optional per-call response queue, so a test can say "first `orders` call raises RateLimited, second succeeds."

Sources:
- [schwab-py HTTP client docs](https://schwab-py.readthedocs.io/en/latest/client.html)
- [schwab-py auth docs](https://schwab-py.readthedocs.io/en/latest/auth.html)
- [schwab-py client/base.py](https://raw.githubusercontent.com/alexgolec/schwab-py/main/schwab/client/base.py)
- [Schwabdev tokens.py](https://raw.githubusercontent.com/tylerebowers/Schwabdev/main/schwabdev/tokens.py)
- [Schwabdev client.py](https://raw.githubusercontent.com/tylerebowers/Schwabdev/main/schwabdev/client.py)
- [sudowealth schwab-api accounts schema](https://unpkg.com/@sudowealth/schwab-api@2.1.1/dist/trader/accounts/schema.js)
- [sudowealth schwab-api orders schema](https://unpkg.com/@sudowealth/schwab-api@2.1.1/dist/trader/orders/schema.js)
- [sudowealth schwab-api transactions schema](https://unpkg.com/@sudowealth/schwab-api@2.1.1/dist/trader/transactions/schema.js)
- [sudowealth schwab-api quotes schema](https://unpkg.com/@sudowealth/schwab-api@2.1.1/dist/market-data/quotes/schema.js)
- [sudowealth schwab-api price history schema](https://unpkg.com/@sudowealth/schwab-api@2.1.1/dist/market-data/price-history/schema.js)
- [sudowealth schwab-api market hours schema](https://unpkg.com/@sudowealth/schwab-api@2.1.1/dist/market-data/market-hours/schema.js)
- [sudowealth schwab-api token.js](https://unpkg.com/@sudowealth/schwab-api@2.1.1/dist/auth/token.js)
- [schwab-client-js DeveloperReference](https://github.com/slimandslam/schwab-client-js/blob/main/docs/DeveloperReference.md)
- [charlesschwabapi R get_orders.R](https://rdrr.io/cran/charlesschwabapi/src/R/get_orders.R)
- [charlesschwabapi R get_transactions.R](https://rdrr.io/cran/charlesschwabapi/src/R/get_transactions.R)
- [scarcefounda/trader Go structs](https://pkg.go.dev/github.com/scarcefounda/trader)
- [tradetally issue 274, same-day transactions window](https://github.com/GeneBO98/tradetally/issues/274)
- [QuantConnect Schwab brokerage docs](https://www.quantconnect.com/docs/v2/cloud-platform/live-trading/brokerages/charles-schwab)
- [api-evangelist charles-schwab rate-limits](https://github.com/api-evangelist/charles-schwab/blob/main/rate-limits/charles-schwab-rate-limits.yml)
- [api-evangelist accounts OpenAPI, confirmed skeletal](https://raw.githubusercontent.com/api-evangelist/charles-schwab/refs/heads/main/openapi/charles-schwab-accounts-api-openapi.yml)
