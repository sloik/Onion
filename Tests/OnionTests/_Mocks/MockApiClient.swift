
// system
import Foundation

// local
import Onion

// 3rd party
import HTTPTypes

actor MockApiClient: APIClientType {

    public let baseURL: URL

    public init(baseURL: URL = URL(string: "https://fake.api.pl")!) {
        self.baseURL = baseURL
    }

    enum E: Error {
        case notTestFlowRequest
    }

    var processedRequests: [Flow] = []
    var runCount = 0
    var uploadCount = 0
    /// `authorization` header of every processed request, in order.
    var sentAuthorization: [String?] = []

    public func run<R: Request>(_ request: R) async throws -> (R.Output, HTTPResponse) {

        guard let testFlowRequest = request as? Flow else {
            throw E.notTestFlowRequest
        }

        runCount += 1
        sentAuthorization.append(request.headerFields[.authorization])
        processedRequests.append(testFlowRequest)

        return try testFlowRequest.response as! (R.Output, HTTPResponse)
    }

    public func upload<R: UploadRequest>(_ request: R) async throws -> (R.Output, HTTPTypes.HTTPResponse) {
        guard let testFlowRequest = request as? Flow else {
            throw E.notTestFlowRequest
        }

        uploadCount += 1
        sentAuthorization.append(request.headerFields[.authorization])
        processedRequests.append(testFlowRequest)

        return try testFlowRequest.response as! (R.Output, HTTPResponse)
    }
}
