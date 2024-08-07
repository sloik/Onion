

import Foundation
import OSLog

import HTTPTypesFoundation
import HTTPTypes

import AliasWonderland
import OptionalAPI

private let logger = Logger(subsystem: "Onion", category: "API Client")

public protocol URLSessionType: Sendable {
    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse)
    func upload(for request: HTTPRequest, from bodyData: Data) async throws -> (Data, HTTPResponse)
}

extension URLSession: URLSessionType {}

public final class APIClient: APIClientType {

    public let baseURL: URL

    private var baseRequest: HTTPRequest {
        HTTPRequest(
            method: .get,
            url: baseURL,
            headerFields: [:]
        )
    }

    private let session: URLSessionType

    public init(
        baseURL: URL,
        session: URLSessionType = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    @discardableResult
    public func run<R: Request>(_ request: R) async throws -> (R.Output, HTTPResponse) {

        let requestID = UUID()

        let httpRequest = httpRequest(from: request)

        logger.debug("\(type(of: self)) \(#function) \(requestID)> Sending request \(type(of: request)) \(httpRequest.url?.absoluteString ?? "-")")

        let (data, httpResponse) = try await session.data(for: httpRequest)

        logger.debug(
            """
            \(type(of: self)) \(#function) \(requestID)> 
                Response: \(httpResponse.debugDescription)
                    Data: \(data.utf8String ?? "-")
            """
        )

        return try commonValidationAndDecode(request: request, data: data, httpResponse: httpResponse)
    }

    public func upload<R: UploadRequest>(_ request: R) async throws -> (R.Output, HTTPResponse) {
        logger.debug("\(type(of: self)) \(#function)> Sending request \(type(of: request))")

        let httpRequest = httpRequest(from: request)

        let (data, httpResponse) = try await session.upload(for: httpRequest, from: request.body.data)

        return try commonValidationAndDecode(request: request, data: data, httpResponse: httpResponse)
    }
}

private extension APIClient {

    func commonValidationAndDecode<R: Request>(request: R, data: Data, httpResponse: HTTPResponse) throws -> (R.Output, HTTPResponse) {

        guard
            case .successful = httpResponse.status.kind
        else {
            logger.error("\(type(of: self)) \(#function)> Request \(type(of: request)) failed with response: \(httpResponse.debugDescription), data: \(data.utf8String ?? "-")")

            throw OnionError.notSuccessStatus(response: httpResponse, data: data)
        }

        if R.Output.self == Data.self {
            return (data as! R.Output, httpResponse)
        }

        let output = try request.decode(data)

        return (output, httpResponse)
    }

    func httpRequest<R: Request>(from request: R) -> HTTPRequest {

        var httpRequest = baseRequest
        httpRequest.path = request.path
        httpRequest.headerFields = request.headerFields
        httpRequest.method = request.method

        return httpRequest
    }
}
