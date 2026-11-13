# Formal model (TLA+)

Two finite TLA+ models of the public semantics of `Sources/Onion`. TLC checks each law over
**every** server/login-handler script of bounded length, not hand-picked examples.

## `OnionRetry.tla` - `NetworkingHandler.run`

The server is a script: `resp[i]` (`ok` / `e401` / `eoth`) is the outcome of the i-th
`apiClient` call, `ref[j]` is the outcome of the j-th `loginHandler.refreshToken()` (`ok`,
`fail` = throws, `notoken` = returns but leaves no token), the login token starts absent or
present, and the request is an upload or not. TLC enumerates all 729 x 27 x 2 x 2 scripts.

| Invariant | Swift behaviour it abstracts |
|---|---|
| `TypeOK` | state shape |
| `BoundedWork` | `tryToLoad`: at most 3 attempts, each at most 1 run + 1 post-refresh run, at most 1 refresh |
| `SuccessMeansLastCallOk` | result is success only if the last `apiClient` call succeeded |
| `HealthyFirstTry` | success on the first call means 1 call, no refresh |
| `RefreshOnlyAfter401` | `refreshToken()` is only reached through the `notSuccessStatus` 401 catch |
| `PlainNeverRefreshes` | `authorizationWithJWTNeeded == false` goes straight to `apiClient.run` |
| `PlainOkIffSomeOk` | plain path succeeds iff one of the 3 attempts succeeds |
| `RetryUsesFreshToken` | after a refresh the resent call carries the new token |
| `CurrentTokenOverridesHeader` | with a token present, the request's `authorization` header is replaced by it |
| `AlwaysDecides` | every run ends in success or an error, never a crash (no `token!`) |
| `RefreshFailsAtMostOnce` | a failed refresh is never retried: at most one per `run`, and it ends the run with `unableToRefreshToken` |
| `ErrorLabelHonest` | `unableToRefreshToken` only when refresh threw, left no token, or the resend was still 401 |
| `StillUnauthorizedEnds` | a resend that is still 401 with the new token ends the run |
| `UploadAlwaysUsesUpload` | an `UploadRequest` always goes through `apiClient.upload`, including the resend |

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
| `OnionRetry.legacy_retries_refresh_failure` | pre-1.0.0: a failed refresh retried by `tryToLoad` | `RefreshFailsAtMostOnce` |
| `OnionRetry.legacy_wraps_resend_errors` | pre-1.0.0: any resend error reported as `unableToRefreshToken` | `ErrorLabelHonest` |
| `OnionRetry.legacy_no_token_crash` | pre-1.0.0: `token!` crash when refresh left no token | `AlwaysDecides` |
| `OnionRetry.legacy_resend_uses_run` | pre-1.0.0: upload resent with `run` | `UploadAlwaysUsesUpload` |
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

## Fixed findings (Onion 1.0.0)

The first version of this model recorded these behaviours as-is. They are fixed in 1.0.0 and
each one survives as a `legacy_*` mutant (table above):

- `tryToLoad` retried on every error, including `unableToRefreshToken`, so a failing refresh
  called `refreshToken()` up to 3 times per `run`.
- Any error from the resend after a refresh (a 500, a decode error) surfaced as
  `unableToRefreshToken`.
- `assert(loginHandler.token.isNotNone)` was debug-only, so in release a refresh that left no
  token crashed at `token!`.
- The resend after a refresh always used `apiClient.run`, even for an `UploadRequest`.

## Limits

The model describes the *intended* semantics, read by hand from the Swift sources. It does not
prove the Swift code conforms; the XCTest suite covers the code. Concurrency, logging,
`URLSession` and Foundation behaviour are out of scope. If the Swift behaviour changes, update
the model in the same PR.
