# Formal model (TLA+)

Two finite TLA+ models of the public semantics of `Sources/Onion`. TLC checks each law over
**every** server/login-handler script of bounded length, not hand-picked examples.

## `OnionRetry.tla` - `NetworkingHandler.run`

The server is a script: `resp[i]` (`ok` / `e401` / `eoth`) is the outcome of the i-th
`apiClient.run` call, `ref[j]` says whether the j-th `loginHandler.refreshToken()` succeeds,
and the login token starts absent or present. TLC enumerates all 729 x 8 x 2 scripts.

| Invariant | Swift behaviour it abstracts |
|---|---|
| `TypeOK` | state shape |
| `BoundedWork` | `tryToLoad`: at most 3 attempts, each at most 1 run + 1 post-refresh run, at most 1 refresh |
| `SuccessMeansLastCallOk` | result is success only if the last `apiClient` call succeeded |
| `HealthyFirstTry` | success on the first call means 1 call, no refresh |
| `RefreshOnlyAfter401` | `refreshToken()` is only reached through the `notSuccessStatus` 401 catch |
| `PlainNeverRefreshes` | `authorizationWithJWTNeeded == false` goes straight to `apiClient.run` |
| `PlainOkIffSomeOk` | plain path succeeds iff one of the 3 attempts succeeds |
| `RetryUsesFreshToken` | after a refresh the retried call carries `.bearer(loginHandler.token!)` (new token) |
| `CurrentTokenOverridesHeader` | with a token present, the request's `authorization` header is replaced by it |
| `AlwaysDecides` | every run ends in success or an error |

## `OnionWire.tla` - pure helpers

| Invariant | Swift behaviour it abstracts |
|---|---|
| `OnlySuccessfulStatusSucceeds`, `NonSuccessNeverDecodes` | `APIClient.commonValidationAndDecode`: `guard case .successful` before decoding |
| `DataOutputSkipsDecoding` | `R.Output.self == Data.self` returns raw data, otherwise `request.decode` |
| `DefaultsAreGetAndAuthorized` | `Request` defaults: `method == .get`, `authorizationWithJWTNeeded == true` (constant-level check) |
| `QueryItemsLimitThenOffset`, `DefaultLimitIs20` | `Paginated.paginationQueryItems` order and `defaultLimit` |
| `BearerFieldUsesBearerScheme` | `BearerToken.httpField` = `Authorization: Bearer <token>` |

Abstractions: HTTP status kinds are the enumerated set `StatusKinds`; JSON decoding is a
boolean; tokens are small sets/naturals; header strings are tagged tuples. `UploadRequest`
routing (`apiClient.upload` vs `run`) has the same retry/refresh shape and is not modelled
separately. `DefaultsAreGetAndAuthorized` and `DefaultLimitIs20` are constant-level
documentation checks; their mutant-resistance is limited by that.

## Non-vacuity

Each `<Module>.<mutant>.cfg` seeds one bug via the `Mutant` constant and names the invariant
that must catch it (`\* EXPECT_VIOLATION: ...`); `run_tlc.sh` fails if a mutant passes.

| Mutant | Seeded bug | Caught by |
|---|---|---|
| `OnionRetry.stale_token` | retry after refresh reuses the old token | `RetryUsesFreshToken` |
| `OnionRetry.ok_on_401` | a 401 is treated as success | `SuccessMeansLastCallOk` |
| `OnionRetry.unauth_refreshes` | plain requests refresh on 401 | `PlainNeverRefreshes` |
| `OnionRetry.ignores_token` | existing token not applied to the header | `CurrentTokenOverridesHeader` |
| `OnionWire.accepts_redirect` | 3xx accepted as success | `OnlySuccessfulStatusSucceeds` |
| `OnionWire.swaps_query_items` | offset before limit | `QueryItemsLimitThenOffset` |
| `OnionWire.basic_scheme` | `Basic` instead of `Bearer` | `BearerFieldUsesBearerScheme` |

## Running

```sh
TLA_JAR=/path/to/tla2tools-1.7.4.jar formal/run_tlc.sh   # needs Java 11+
```

The script checks the jar's SHA-256 against the pinned tla2tools 1.7.4. CI runs it on a
self-hosted Oracle ARM64 runner, only on pushes to `main` or by manual dispatch
(`.github/workflows/oracle-tla.yml`). The Swift build and tests stay on hosted macOS.

## Findings (behaviours the model records; Swift unchanged)

These are not law violations, but they are surprising and the model encodes them as-is:

- `tryToLoad` retries on **every** error, including `unableToRefreshToken`, so a failing
  refresh can call `refreshToken()` up to 3 times per `run`.
- Inside the refresh helper, the `do/catch` wraps the post-refresh `apiClient.run` too, so any
  error from the retried call (including a second 401 or a decode error) surfaces as
  `unableToRefreshToken`, and there is no second refresh within one attempt.
- `assert(loginHandler.token.isNotNone)` after refresh is debug-only; in release a nil token
  would crash at `token!`. Not modelled (the script's tokens are always present after refresh).

## Limits

The model describes the *intended* semantics, read by hand from the Swift sources. It does not
prove the Swift code conforms; the XCTest suite covers the code. Concurrency, logging,
`URLSession` and Foundation behaviour are out of scope. If the Swift behaviour changes, update
the model in the same PR.
