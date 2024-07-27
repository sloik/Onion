
import Foundation

import HTTPTypes

final class MockNetworkingHandler: NetworkingHandlerType {

    public init() {}

    public func run<R: Request>(_ request: R) async throws -> (R.Output, HTTPResponse) {
        fatalError("MockNetworkingHandler.run not implemented")
    }
}
