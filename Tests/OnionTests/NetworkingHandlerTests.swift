import XCTest

import Onion
import HTTPTypes

import ExTests
import AliasWonderland

final class NetworkingHandlerTests: XCTestCase {

    var apiClient: MockApiClient!
    var loginHandler: MockLoginHandler!
    var sut: NetworkingHandler!


    override func setUp() async throws {
        try await super.setUp()

        apiClient = MockApiClient()
        loginHandler = MockLoginHandler()

        sut = NetworkingHandler(apiClient: apiClient, loginHandler: loginHandler)
    }

    override func tearDown() async throws {
        sut = .none
        loginHandler = .none
        apiClient = .none

        try await super.tearDown()
    }

    /// When running a `Request`
    ///
    /// ## **Expected behaviour:**
    ///
    /// - `APIClient` should be used to run the request.
    /// - Data should be returned
    /// - `HTTPStatus` should be returned
    func test_shouldUseApiClientToRunRequests() async throws {

        // Arrange
        let flow = Flow.okResponse

        // Act
        do {
            let (response, httpResponse) = try await sut.run(flow)

            // Assert
            XCTAssertEqual(response, .mock)
            XCTAssertEqual(httpResponse.status, .ok)

            let result = await apiClient.processedRequests.map(\.tag)
            XCTAssertEqual(
                result,
                ["Ok Request"]
            )
        } catch {
            XCTFail("Should not throw!")
        }
    }

    /// When running a `Request` and it fails
    ///
    /// ## **Expected behaviour:**
    ///
    /// - request should be retried 3x
    /// - result of final error should be returned
    func test_run_whenSessionFails_shouldTryRequestMaxThreeTimes() async throws {
        // Arrange

        let expectedError = "Some error in running the request!"
        let dataRequestExpectation = expectation(description: "Should call dataForRequest 3 times").expect(3).strict()

        let flow = Flow.throwingResponse

        flow.responseProducer = {
            dataRequestExpectation.fulfill()
            throw expectedError
        }

        // Act & Assert
        do {
            try await sut.run( flow )
            XCTFail("Should not throw")
        } catch let error as String {
            XCTAssertEqual(error, expectedError)

            let result = await apiClient.processedRequests.map(\.tag)

            XCTAssertEqual(
                result,
                ["Throwing Request", "Throwing Request", "Throwing Request"]
            )

            await fulfillment(of: [dataRequestExpectation], timeout: 0.1)
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }

    }

    /// When running a `Request` that has `authorization` header and the
    /// token is invalid.
    ///
    /// ## **Expected behaviour:**
    ///
    /// - should try to refresh token
    /// - when refreshed the initial request should be retried
    func test_tryToRunAndRefreshTokenWhenNeededAndRetryTheRequest() async throws {
        // Arrange
        let didRefreshToken = expectation(description: "Did not refresh token!").onceStrict()
        let didRetryTheRequest = expectation(description: "Should retry the request!").onceStrict()

        let fulfillRetryRequestAndReturnOkResponse: ThrowsProducer<(FlowResponse, HTTPResponse)> = {
            didRetryTheRequest.fulfill()
            return try Flow.okResponse.response
        }

        // Start with a flow that need a token and throws an unauthorized response error.
        let flow = Flow.unauthorizedResponse
        flow.responseProducer = {
            throw OnionError.notSuccessStatus(response: .init(status: .unauthorized), data: Data())
        }

        // Check that token was refreshed
        loginHandler.refreshTokenClosure = { _ in
            didRefreshToken.fulfill()
            self.loginHandler.tokenProducer = { "updated token" }
            flow.responseProducer = fulfillRetryRequestAndReturnOkResponse
        }

        // Act
        do {
            let (output, response) = try await sut.run(flow)

            await fulfillment(
                of: [
                    didRefreshToken,
                    didRetryTheRequest
                ],
                timeout: 0.1,
                enforceOrder: true
            )

            XCTAssertEqual(output, .mock)
            XCTAssertEqual(response, .init(status: .ok))
        } catch {
            XCTFail("No erros should be thrown!")
        }
    }


    /// When running a `Request` that has `authorization` header 
    /// **and** the the token is invalid,
    /// **and** unable to refresh token.
    ///
    /// ## **Expected behaviour:**
    ///
    /// - should throw an error that cannot refresh token
    func test_run_shouldThrowAnErrorWhenUnableToRefreshToken() async throws {

        // Arrange

        // Start with a flow that need a token and throws an unauthorized response error.
        let flow = Flow.unauthorizedResponse
        flow.responseProducer = {
            throw OnionError.notSuccessStatus(response: .init(status: .unauthorized), data: Data())
        }

        // Throw an error when trying to refresh token
        let expectedError = "Simulated error while refreshing token"
        loginHandler.refreshTokenClosure = { _ in
            throw expectedError
        }

        // Act & Assert
        do {
            let _ = try await sut.run(flow)

            XCTFail("Should throw an error!")
        } catch NetworkingHandlerError.unableToRefreshToken(let underlyingError) {
            XCTAssertEqual(
                underlyingError as? String,
                expectedError,
                "Should pass the underlying error from the refresh token method!"
            )
        } catch {
            XCTFail("Should throw a different error but got: \(error)")
        }
    }

    
    /// When running a `Request` that has `authorization` header
    /// **and** the the token is invalid,
    /// **and** error is unknown or unexpected
    ///
    /// ## **Expected behaviour:**
    ///
    /// - should rethrow the underlying error to the upper layers
    func test_run_shouldRethrowAnyNotHandeledErrors() async throws {
        // Arrange
        let expectedError = "Some error did occur"

        let flow = Flow.unauthorizedResponse
        flow.responseProducer = { throw expectedError }

        // Act & Assert
        do {
            let _ = try await sut.run(flow)

            XCTFail("Should throw an error!")
        } catch let error as String {
            XCTAssertEqual(
                error,
                expectedError,
                "Should pass the underlying error from the refresh token method!"
            )
        } catch {
            XCTFail("Should throw a different error but got: \(error)")
        }
    }

    /// After a 401 and a successful refresh, the request is sent again with the NEW token.
    func test_run_whenTokenIsRefresh_shouldUpdateRequestWithNewToken() async throws {
        let flow = Flow.unauthorizedResponse
        loginHandler.tokenProducer = { "old token" }
        flow.responseProducer = {
            throw OnionError.notSuccessStatus(response: .init(status: .unauthorized), data: Data())
        }
        loginHandler.refreshTokenClosure = { _ in
            self.loginHandler.tokenProducer = { "new token" }
            flow.responseProducer = { try Flow.okResponse.response }
        }

        let (output, _) = try await sut.run(flow)

        XCTAssertEqual(output, .mock)
        let sent = await apiClient.sentAuthorization
        XCTAssertEqual(sent, ["Bearer old token", "Bearer new token"])
    }

    // MARK: - Regressions (1.0.0 retry/refresh contract)

    /// A failing refresh is not retried: refreshToken() runs once per run().
    func test_run_whenRefreshFails_shouldRefreshOnlyOnce() async throws {
        let flow = Flow.unauthorizedResponse
        flow.responseProducer = {
            throw OnionError.notSuccessStatus(response: .init(status: .unauthorized), data: Data())
        }
        var refreshCalls = 0
        loginHandler.refreshTokenClosure = { _ in
            refreshCalls += 1
            throw "refresh failed"
        }

        do {
            _ = try await sut.run(flow)
            XCTFail("Should throw")
        } catch NetworkingHandlerError.unableToRefreshToken {
            XCTAssertEqual(refreshCalls, 1)
            let sends = await apiClient.processedRequests.count
            XCTAssertEqual(sends, 1)
        }
    }

    /// A non-401 error from the request sent after a refresh is thrown as itself, not as
    /// unableToRefreshToken. Every attempt: first send 401, send after refresh 500.
    func test_run_whenRetryAfterRefreshFailsWithOtherError_shouldThrowThatError() async throws {
        let flow = Flow.unauthorizedResponse
        var sends = 0
        flow.responseProducer = {
            sends += 1
            let status: HTTPResponse.Status = sends % 2 == 1 ? .unauthorized : .internalServerError
            throw OnionError.notSuccessStatus(response: .init(status: status), data: Data())
        }
        loginHandler.refreshTokenClosure = { _ in
            self.loginHandler.tokenProducer = { "new token" }
        }

        do {
            _ = try await sut.run(flow)
            XCTFail("Should throw")
        } catch OnionError.notSuccessStatus(let response, _) {
            XCTAssertEqual(response.status, .internalServerError)
        } catch {
            XCTFail("Expected the server error, got \(error)")
        }
    }

    /// Still 401 with the refreshed token: unableToRefreshToken, refresh not repeated.
    func test_run_whenStillUnauthorizedAfterRefresh_shouldThrowUnableToRefreshOnce() async throws {
        let flow = Flow.unauthorizedResponse
        flow.responseProducer = {
            throw OnionError.notSuccessStatus(response: .init(status: .unauthorized), data: Data())
        }
        var refreshCalls = 0
        loginHandler.refreshTokenClosure = { _ in
            refreshCalls += 1
            self.loginHandler.tokenProducer = { "new token" }
        }

        do {
            _ = try await sut.run(flow)
            XCTFail("Should throw")
        } catch NetworkingHandlerError.unableToRefreshToken(let underlying) {
            XCTAssertEqual(refreshCalls, 1)
            guard case OnionError.notSuccessStatus(let response, _)? = underlying as? OnionError else {
                return XCTFail("Underlying error should be the 401, got \(underlying)")
            }
            XCTAssertEqual(response.status, .unauthorized)
        }
    }

    /// refreshToken() succeeds but leaves no token: an error, not a crash on `token!`.
    func test_run_whenRefreshLeavesNoToken_shouldThrowInsteadOfCrashing() async throws {
        let flow = Flow.unauthorizedResponse
        flow.responseProducer = {
            throw OnionError.notSuccessStatus(response: .init(status: .unauthorized), data: Data())
        }
        loginHandler.refreshTokenClosure = { _ in
            self.loginHandler.tokenProducer = nil
        }

        do {
            _ = try await sut.run(flow)
            XCTFail("Should throw")
        } catch NetworkingHandlerError.unableToRefreshToken(let underlying) {
            XCTAssertTrue(underlying is TokenMissingAfterRefresh)
        }
    }

    /// An upload request sent again after a refresh still goes through upload(), not run().
    func test_run_uploadRetriedAfterRefresh_shouldUseUpload() async throws {
        let flow = Flow.unauthorizedResponse   // Flow is an UploadRequest
        flow.responseProducer = {
            throw OnionError.notSuccessStatus(response: .init(status: .unauthorized), data: Data())
        }
        loginHandler.refreshTokenClosure = { _ in
            self.loginHandler.tokenProducer = { "new token" }
            flow.responseProducer = { try Flow.okResponse.response }
        }

        _ = try await sut.run(flow)

        let runs = await apiClient.runCount
        let uploads = await apiClient.uploadCount
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(uploads, 2)
    }
}
