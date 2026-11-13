# Changelog

This project follows [Semantic Versioning 2.0.0](https://semver.org).

## 1.0.0 (2026-11-13): breaking

**Why a major version:** `NetworkingHandler.run` now reports and retries errors differently.
Apps often react to `NetworkingHandlerError.unableToRefreshToken`, for example by logging
the user out, and that error is now thrown in fewer cases. That is a change to the public error
contract, so the major version goes up. 1.0.0 is also the first release with a stable API.

The bugs were found by the TLA+ model in `formal/`. Each has a regression test in
`Tests/OnionTests/NetworkingHandlerTests.swift`, and each fails on 0.0.3.

### Breaking: error contract of `NetworkingHandler.run`

| Situation | 0.0.3 | 1.0.0 |
|---|---|---|
| Request gets 401, `refreshToken()` throws | `unableToRefreshToken`, after **3** refresh attempts (the whole run was retried) | `unableToRefreshToken` after **1** refresh attempt; not retried |
| 401, refresh succeeds, resend fails with another error (500, decode error, ...) | `unableToRefreshToken(underlyingError: thatError)` | `thatError` itself, retried like any request error |
| 401, refresh succeeds, resend is **still 401** with the new token | `unableToRefreshToken`, and the run retried (refreshing again) | `unableToRefreshToken(underlyingError: the 401)`; not retried |
| 401, `refreshToken()` returns but `token` is still `nil` | release build: **crash** (`token!`); debug: assertion failure | `unableToRefreshToken(underlyingError: TokenMissingAfterRefresh())` |

So in 1.0.0, `unableToRefreshToken` always means that the session's token could not be renewed.
If you log the user out on it, that stays correct. A server error after a successful refresh no
longer logs them out.

### Fixes

- An `UploadRequest` that is resent after a token refresh now goes through `apiClient.upload`
  (0.0.3 resent it with `apiClient.run`).
- A request that needs a JWT now uses `loginHandler.token` without force-unwrapping.

### Added

- `public struct TokenMissingAfterRefresh: Error`, the underlying error when a refresh leaves no
  token.

### Migrating

- If you `catch NetworkingHandlerError.unableToRefreshToken` to log out, you need no change.
- If you relied on `unableToRefreshToken` wrapping *other* failures after a refresh, catch those
  errors (for example `OnionError.notSuccessStatus`) directly.
- If your `refreshToken()` can return without setting a token, handle
  `TokenMissingAfterRefresh` as the underlying error. This used to crash.
- `refreshToken()` is now called at most once per failed `run`. If you counted on the old retries
  to recover from a flaky refresh endpoint, retry inside `refreshToken()`.
