
// System
import Foundation
import OSLog

// Local

// 3rd party
import HTTPTypes
import AliasWonderland

private let logger = Logger(subsystem: "Onion", category: "NetworkingHandler")

public final class NetworkingHandler: Sendable {

    let apiClient: APIClientType

    let loginHandler: LoginHandlerType

    public init(
        apiClient: APIClientType,
        loginHandler: LoginHandlerType
    ) {
        self.apiClient = apiClient
        self.loginHandler = loginHandler
    }
}

public enum NetworkingHandlerError: Error {

    /// Thrown when the request was rejected as unauthorised (401) and the token could not be
    /// renewed: `refreshToken()` failed, left no token, or the request was still unauthorised
    /// with the new token. It is never retried, so `refreshToken()` runs at most once per `run`.
    /// Other errors from the request sent after a refresh are thrown unchanged.
    case unableToRefreshToken(underlyingError: Error)
}

/// `refreshToken()` returned without error but `LoginHandlerType.token` is still `nil`.
public struct TokenMissingAfterRefresh: Error {}

extension NetworkingHandler: NetworkingHandlerType {

    @discardableResult
    public func run<R: Request>(_ request: R) async throws -> (R.Output, HTTPResponse) {
        try await tryToLoad {
            if request.authorizationWithJWTNeeded {
                var copy = request
                // Override or add auth header with the latest token.
                if let token = loginHandler.token {
                    copy.headerFields[.authorization] = .bearer(token)
                }
                return try await tryToRunAndRefreshTokenWhenNeeded(copy)
            } else {
                return try await apiClient.run(request)
            }
        }
    }
}

private extension NetworkingHandler {

    /// Runs `action` up to 3 times in total when it throws.
    /// A `NetworkingHandlerError` is thrown at once: retrying it would only refresh the token again.
    func tryToLoad<A,B>(action: AsyncThrowsProducer<A,B>) async throws -> (A, B) {

        for _ in 1...2 {
            do {
                return try await action()
            } catch let error as NetworkingHandlerError {
                throw error
            } catch {
                logger.error("\(type(of: self)) \(#function)> Error while trying to load data: \(error)")
                continue
            }
        }

        // try it 3rd and last time
        return try await action()
    }

    /// Sends `request` with `upload` when it is an `UploadRequest`, otherwise with `run`.
    func execute<R: Request>(_ request: R) async throws -> (R.Output, HTTPResponse) {
        if let uploadRequest = request as? any UploadRequest {
            let (content, response) = try await apiClient.upload(uploadRequest)
            return (content as! R.Output, response)
        }
        return try await apiClient.run(request)
    }

    func tryToRunAndRefreshTokenWhenNeeded<R: Request>(_ request: R) async throws -> (R.Output, HTTPResponse) {

        func refreshTokenAndTriggerRequestOneMoreTime() async throws -> (R.Output, HTTPResponse) {
            logger.debug("\(type(of: self)) \(#function)> Refreshing token and trying to run request \(type(of: R.self))")

            let token: String
            do {
                try await loginHandler.refreshToken()
                guard let refreshed = loginHandler.token else { throw TokenMissingAfterRefresh() }
                token = refreshed
            } catch {
                logger.error("\(type(of: self)) \(#function)> Unable to refresh token with error: \(error.localizedDescription)")
                throw NetworkingHandlerError.unableToRefreshToken(underlyingError: error)
            }

            var copy = request
            copy.headerFields[.authorization] = .bearer(token)

            do {
                return try await execute(copy)
            } catch let error as OnionError {
                // Still unauthorised with the new token: the token is not valid.
                if case .notSuccessStatus(let response, _) = error, response.status.code == 401 {
                    throw NetworkingHandlerError.unableToRefreshToken(underlyingError: error)
                }
                throw error
            }
        }

        do {
            logger.debug("\(type(of: self)) \(#function)> Trying to run request \(type(of: request))")
            return try await execute(request)
        }
        // Catch error related expired JWT
        catch OnionError.notSuccessStatus(let response, _) where response.status.code == 401 {
            logger.debug("\(type(of: self)) \(#function)> Unauthorised request \(type(of: request))")

            return try await refreshTokenAndTriggerRequestOneMoreTime()

        } catch {
            logger.error("Error running \(type(of: request)) with error: \(error.localizedDescription)")
            throw error
        }
    }
}
