# Schwab API contract (working reference for `Schwab::Client`)

Compiled 2026-09-01 from schwab-py, Schwabdev, the sudowealth TypeScript schemas, schwab-client-js, the R `charlesschwabapi` package, and QuantConnect, via the counselors review in `agents/counselors/1788298377-*`. The api-evangelist OpenAPI files are skeletal and are not used for shapes. Nothing here has been confirmed against Schwab's portal; `docs/verify-on-approval.md` lists what to check once the app is Ready For Use. Adapter code marks each assumption `# SCHWAB_SHAPE_UNVERIFIED`.

Hosts: `https://api.schwabapi.com/trader/v1` and `https://api.schwabapi.com/marketdata/v1`. Every API call sends `Authorization: Bearer <access_token>` and `Accept: application/json`. Responses are bare arrays or objects, no envelope.

## Rules the client enforces

1. **Plaintext account numbers are scrubbed in the client**, before anything else sees a body: `accountNumber` appears on `/accounts/accountNumbers`, `securitiesAccount.accountNumber`, `order.accountNumber` (integer), and `transaction.accountNumber`. Scrubbing here covers `raw` jsonb, cassettes, and logs in one place.
2. **Logs carry path templates**, e.g. `/accounts/{hash}/orders`, never the hash. Never bodies, headers, or query values.
3. **All money and quantities parse through `BigDecimal(value.to_s)`.** `price` may arrive as a number or a string.
4. **One time helper** handles `+0000`, `Z`, `-04:00`, and epoch milliseconds in, and produces `yyyy-MM-dd'T'HH:mm:ss.SSSZ` (UTC), `YYYY-MM-DD`, and epoch ms out.
5. **Callers pass `Time` objects.** Formatting is the client's job.
6. **Rate budget is shared** across Puma and the Solid Queue worker: a Solid Cache counter, 100 requests/minute (limit unverified; 120 is the community figure).
7. **Retries:** GETs and the refresh grant only, on 429 and 5xx and transport errors; 1, 4, 16 seconds with jitter, `Retry-After` honored but capped at 60 s. Never retry 4xx. One refresh-and-retry on a 401 outside the budget.
8. **Mappers never crash a sync.** Unknown enum values are stored raw and mapped to `unknown`/`other`; missing optional fields are nil; a record that cannot be identified is quarantined with its raw JSON and counted on the `sync_runs` row, and the run finishes `partial`.

## Error taxonomy

`Schwab::Error` (status, scrubbed body, request id from `errors[].id`, attempts) with subclasses callers rescue separately:

| Class | When |
|---|---|
| `Schwab::AuthError` | API 401 after the one refresh-and-retry |
| `Schwab::ReauthRequired < AuthError` | any token-endpoint 4xx (`invalid_client`, `invalid_grant`, `refresh_token_authentication_error`, `unsupported_token_type`); the pause path |
| `Schwab::RateLimited` (`retry_after`) | 429 after the retry budget |
| `Schwab::ServerError` | 5xx after retries |
| `Schwab::RequestError` | 400, 403, 404; never retried; a 400 on `startDate` is how the lookback cap announces itself |
| `Schwab::TransportError` | timeout or connection failure on an idempotent call |
| `Schwab::UnknownOutcome` | the same failures on a non-idempotent call (Phase 2 order POST); chosen by HTTP method so it can never be confused with the line above |
| `Schwab::MappingError` | a required field is missing; rescued per record by the sync job |

Error bodies: API errors are JSON:API style `{"errors":[{"id","status","title","detail","source"}]}`; the token endpoint uses `{"error","error_description"}`; gateway 401s and 5xxs can be non-JSON. The parser tolerates all three.

## OAuth

| Item | Value |
|---|---|
| Authorize | `GET /v1/oauth/authorize?response_type=code&client_id={app_key}&redirect_uri={callback}&state={csrf}` |
| Callback | `{callback}?code=...&session=...`; `code` ends in `@` after one URL-decode. Rails `params[:code]` is already decoded once; do not decode again |
| Token endpoint | `POST /v1/oauth/token`, `Authorization: Basic base64("#{app_key}:#{app_secret}")`, `Content-Type: application/x-www-form-urlencoded` |
| Code grant | `grant_type=authorization_code&code={code}&redirect_uri={callback}` |
| Refresh grant | `grant_type=refresh_token&refresh_token={token}` |
| Token response | `{"expires_in":1800,"token_type":"Bearer","scope":"api","refresh_token","access_token","id_token"}`; `id_token` is not persisted |
| Access token | 30 minutes; expired tokens are rejected outright (API 401) |
| Refresh token | 7 days from the authorization-code grant. **Refreshing does not extend it.** `refresh_expires_at` is set once at issuance and never moved |
| Refresh response | includes a `refresh_token`; store whatever comes back, keep `refresh_expires_at` |

The refresh job runs every 25 minutes. A token-endpoint 4xx is `ReauthRequired`: no backoff, no retry, pause sync.

## Trader API

### `GET /accounts/accountNumbers`
Response `[{"accountNumber":"<plaintext>","hashValue":"<hash>"}]`. The client returns hash values only.

### `GET /accounts/{hash}?fields=positions`
`/accounts` (no hash) returns an array without `hashValue`, so linking would require plaintext numbers. Call `/accounts/{hash}` once per hash instead. Balances come by default; `fields=positions` adds positions.

```
{ "securitiesAccount": {
    "type": "CASH"|"MARGIN", "accountNumber": <scrubbed>, "roundTrips", "isDayTrader", "isClosingOnlyRestricted", "pfcbFlag",
    "positions": [ { "longQuantity", "shortQuantity", "settledLongQuantity", "settledShortQuantity",
                     "averagePrice", "averageLongPrice", "taxLotAverageLongPrice", "marketValue",
                     "currentDayProfitLoss", "currentDayProfitLossPercentage", "currentDayCost", "longOpenProfitLoss",
                     "instrument": { "assetType", "cusip"?, "symbol", "description"?, "instrumentId"?, "netChange", "type"? } } ],
    "initialBalances": {...}, "currentBalances": {...}, "projectedBalances": { "cashAvailableForTrading", "cashAvailableForWithdrawal" } },
  "aggregatedBalance": { "currentLiquidationValue", "liquidationValue" } }
```

`instrument.assetType`: EQUITY, OPTION, MUTUAL_FUND, CASH_EQUIVALENT, FIXED_INCOME, INDEX, CURRENCY, COLLECTIVE_INVESTMENT, FUTURE, FOREX, PRODUCT. The accounts API says EQUITY for ETFs where the quotes API says ETF; `instruments.asset_type` comes from the Trader API only. `cusip` and `instrumentId` are optional; cash equivalents and options often lack a CUSIP.

Cash-account `currentBalances`: `cashAvailableForTrading`, `cashAvailableForWithdrawal`, `cashCall`, `longNonMarginableMarketValue`, `totalCash`, `cashDebitCallValue`, `unsettledCash`, `accruedInterest`, `cashBalance`, `cashReceipts`, `longOptionMarketValue`, `liquidationValue`, `longMarketValue`, `moneyMarketFund`, `savings`, `shortMarketValue`, `pendingDeposits`, `mutualFundValue`, `bondValue`, `shortOptionMarketValue`.

Balance mapping: `equity` = `liquidationValue`; `cash_available_for_trading`; `unsettled_cash`; `cash_available_for_withdrawal`; `buying_power` nil for CASH. **`settled_cash` is derived, not a Schwab field.** Reading A: `cashAvailableForTrading - unsettledCash`. Reading B: `cashAvailableForWithdrawal`. Conservative: `min(A, B)` when both present. One named method, one spec per reading; Phase 2 guardrail 4 reads it.

### `GET /accounts/{hash}/orders?fromEnteredTime=&toEnteredTime=&maxResults=3000[&status=]`
`fromEnteredTime` and `toEnteredTime` are required together, `.SSSZ` UTC. Lookback is 60 days (schwab-py) or one year (Schwabdev); use 60 as one constant. `status` takes one enum value. `maxResults` default and max 3000; send it.

**Also `GET /accounts/{hash}/orders/{orderId}`** for one order. Known working stops older than the lookback are re-fetched by id, otherwise positions get falsely flagged unprotected.

```
{ "orderId": <int64>, "accountNumber": <scrubbed>, "status", "statusDescription",
  "orderType": MARKET|LIMIT|STOP|STOP_LIMIT|TRAILING_STOP|TRAILING_STOP_LIMIT|MARKET_ON_CLOSE|LIMIT_ON_CLOSE|CABINET|NON_MARKETABLE|EXERCISE|NET_DEBIT|NET_CREDIT|NET_ZERO|UNKNOWN,
  "session": NORMAL|AM|PM|SEAMLESS, "duration": DAY|GOOD_TILL_CANCEL|FILL_OR_KILL|IMMEDIATE_OR_CANCEL|END_OF_WEEK|END_OF_MONTH|NEXT_END_OF_MONTH|UNKNOWN,
  "orderStrategyType": SINGLE|OCO|TRIGGER|CANCEL|RECALL|PAIR|FLATTEN|TWO_DAY_SWAP|BLAST_ALL,
  "quantity", "filledQuantity", "remainingQuantity", "price", "stopPrice", "stopType", "activationPrice",
  "taxLotMethod": FIFO|LIFO|HIGH_COST|LOW_COST|AVERAGE_COST|SPECIFIC_LOT|LOSS_HARVESTER,
  "enteredTime": "2026-08-14T13:31:02+0000", "closeTime", "cancelTime", "releaseTime", "cancelable", "editable", "tag",
  "orderLegCollection": [ { "legId", "orderLegType", "instruction": BUY|SELL|BUY_TO_COVER|SELL_SHORT|BUY_TO_OPEN|BUY_TO_CLOSE|SELL_TO_OPEN|SELL_TO_CLOSE|EXCHANGE|SELL_SHORT_EXEMPT,
                            "positionEffect": OPENING|CLOSING|AUTOMATIC, "quantity", "quantityType", "instrument": {...} } ],
  "orderActivityCollection": [ { "activityType": EXECUTION|ORDER_ACTION, "executionType": "FILL", "quantity", "orderRemainingQuantity",
                                 "executionLegs": [ { "legId", "price", "quantity", "mismarkedQuantity", "instrumentId", "time" } ] } ],
  "childOrderStrategies": [ <full orders, recursive> ], "replacingOrderCollection": [ <full orders> ] }
```

Status enum: AWAITING_PARENT_ORDER, AWAITING_CONDITION, AWAITING_STOP_CONDITION, AWAITING_MANUAL_REVIEW, ACCEPTED, AWAITING_UR_OUT, PENDING_ACTIVATION, QUEUED, WORKING, REJECTED, PENDING_CANCEL, CANCELED (one L), PENDING_REPLACE, REPLACED, FILLED, EXPIRED, NEW, AWAITING_RELEASE_TIME, PENDING_ACKNOWLEDGEMENT, PENDING_RECALL, UNKNOWN.

Working set for stop detection: WORKING, ACCEPTED, QUEUED, PENDING_ACTIVATION, AWAITING_PARENT_ORDER, AWAITING_STOP_CONDITION, AWAITING_CONDITION, NEW, AWAITING_RELEASE_TIME. A bracket child sits in AWAITING_PARENT_ORDER until the parent fills.

Bracket children and replacements are **nested**, each a full order with its own `orderId`. The sync flattens recursively, setting `parent_order_id` and `replaces_order_id` as it walks.

### `GET /accounts/{hash}/transactions?startDate=&endDate=[&types=][&symbol=]`
`startDate`/`endDate` required together, `.SSSZ`, inclusive; a same-day query needs `endDate` at `23:59:59.000Z`. Lookback 60 days (same constant). `types` takes one value: TRADE, RECEIVE_AND_DELIVER, DIVIDEND_OR_INTEREST, ACH_RECEIPT, ACH_DISBURSEMENT, CASH_RECEIPT, CASH_DISBURSEMENT, ELECTRONIC_FUND, WIRE_OUT, WIRE_IN, JOURNAL, MEMORANDUM, MARGIN_CALL, MONEY_MARKET, SMA_ADJUSTMENT. Whether omitting it returns everything is unverified; the client loops the types the sync cares about.

```
{ "activityId": <int64, upsert key>, "time": "2026-08-14T13:31:02+0000", "user": {...drop...}, "description", "accountNumber": <scrubbed>,
  "type", "status": VALID|INVALID|PENDING|UNKNOWN, "subAccount": CASH|MARGIN|SHORT|DIV|INCOME|UNKNOWN,
  "tradeDate": "2026-08-14T00:00:00+0000", "settlementDate", "positionId", "orderId"?, "netAmount": <signed cash impact>,
  "activityType": EXECUTION|ORDER_ACTION|TRANSFER|ACTIVITY_CORRECTION|UNKNOWN,
  "transferItems": [ { "instrument": { "assetType":"EQUITY","cusip","symbol","instrumentId" }, "amount": <shares>, "cost", "price", "positionEffect" },
                     { "instrument": { "assetType":"CURRENCY","symbol":"CURRENCY_USD" }, "amount": <dollars>, "feeType": "SEC_FEE" } ] }
```

The security item is the one without `feeType` whose instrument is not CURRENCY; its `amount` is share quantity. Fee items carry `feeType` (COMMISSION, SEC_FEE, STR_FEE, R_FEE, CDSC_FEE, OPT_REG_FEE, ADDITIONAL_FEE, MISCELLANEOUS_FEE, FUTURES_EXCHANGE_FEE, LOW_PROCEEDS_COMMISSION, BASE_CHARGE, GENERAL_CHARGE, GST_FEE, TAF_FEE, INDEX_OPTION_FEE, UNKNOWN) and `amount` in dollars. Side is derived from `positionEffect` plus the sign of `netAmount`; fees are the sum of `feeType` items, never from `cost`. `orderId` is present on TRADE executions only. Sign conventions and every corporate-action shape are unverified; RECEIVE_AND_DELIVER is the type for splits and CUSIP successions.

## Market Data API

### `GET /marketdata/v1/markets?markets=equity,option&date=YYYY-MM-DD`
One date per call, today to one year out. Open day: `{"equity":{"EQ":{"date","marketType","product","isOpen":true,"sessionHours":{"preMarket":[{"start","end"}],"regularMarket":[...],"postMarket":[...]}}}}` with `-04:00` offsets. Closed day (TD-era behavior, unverified): key changes from `EQ` to `equity`, `sessionHours` absent, `isOpen` false. The mapper takes the first value under `equity` regardless of key, treats missing `sessionHours` as closed, and uses min start and max end per session. Early closes show as a shorter `regularMarket` interval.

### `GET /marketdata/v1/quotes?symbols=A,B&fields=quote,reference&indicative=false`
Symbols comma-joined and URL-encoded; chunk at 100. Response keyed by symbol: `assetMainType` (EQUITY|ETF|...), `assetSubType`, `quoteType`, `realtime`, `ssid`, `symbol`, `reference` {cusip, description, exchange, exchangeName}, `quote` {askPrice, bidPrice, lastPrice, mark, netChange, netPercentChange, openPrice, highPrice, lowPrice, closePrice, totalVolume, quoteTime, tradeTime, securityStatus, 52WeekHigh, 52WeekLow}, `regular` {regularMarketLastPrice, ...}. `quoteTime`/`tradeTime` are epoch ms. Unknown symbols return in the same 200 under a top-level `errors` key (`{"errors":{"invalidSymbols":[...]}}`); the mapper skips it and reports the list.

### `GET /marketdata/v1/pricehistory?symbol=&periodType=&period=&frequencyType=&frequency=[&startDate=&endDate=]&needExtendedHoursData=false&needPreviousClose=true`
`startDate`/`endDate` are epoch ms and override `period`. Valid combinations: day (1,2,3,4,5,10) with minute (1,5,10,15,30); month (1,2,3,6) with daily or weekly; year (1,2,3,5,10,15,20) with daily, weekly, monthly; ytd (1) with daily or weekly. Response `{"candles":[{"open","high","low","close","volume","datetime":<epoch ms>}],"symbol","empty","previousClose","previousCloseDate"}`. Daily `datetime` is midnight Eastern in UTC ms: convert in America/New_York. For the collar engine: `periodType=month&period=3&frequencyType=daily`.

### `GET /marketdata/v1/instruments?symbol=&projection=symbol-search` and `GET /marketdata/v1/instruments/{cusip}`
`{"instruments":[{"cusip","symbol","description","exchange","assetType"}]}`. The fallback for a position or transaction that arrives without a CUSIP. Preserve leading zeros.

## Limits

| Limit | Value used | Notes |
|---|---|---|
| Orders and transactions lookback | 364 days, one constant | Live probe 2026-09-01: 364-day windows return 200 on both endpoints |
| Read rate limit | 100/min shared budget | community says 120/min per app, all APIs; unverified |
| 429 handling | back off 1, 4, 16 s with jitter; `Retry-After` capped at 60 s | `Retry-After` presence unverified |
| Quotes per call | 100 symbols | undocumented |
| `maxResults` | 3000, sent explicitly | |
| Market hours | one date per call, from 7 days back to +1 year | past dates beyond 7 days are a 400 (live probe) |
| Order write limit (Phase 2) | 120/min, 4000/day | QuantConnect figure |

## FakeClient

`Schwab::FakeClient` sits **below the mappers**: it returns scrubbed raw hashes in the same shape as the HTTP client, so seeds and Playwright exercise the mapping code where every shape assumption lives, and its fixtures double as the cassette-shaped fixtures for specs. It scripts auth too (`authorize_url`, `exchange_code`, `refresh`) and supports a per-call response queue so a test can say "first `orders` call raises RateLimited, second succeeds". Scenarios: re-auth success and failure, refresh expired, rate limited then success, server error then success, transport timeout, empty account, position removed between syncs, nested bracket child, transaction with missing CUSIP, unknown enum value, closed market day, quotes batch with one invalid symbol, and the four dashboard banner states.
