
import XCTest

@testable import Onion

import HTTPTypes
import InlineSnapshotTesting

final class PaginatedTests: XCTestCase {


    func test_paginationQueryItems_shouldContainValuesForOffsetAndLimit() {
        // Arrange
        let expectedOffset: Int = 42
        let expectedLimit : Int = 69

        let sut = Req(offset: expectedOffset, limit: expectedLimit)

        // Act
        let result: [URLQueryItem] = sut.paginationQueryItems

        // Assert
        assertInlineSnapshot(of: result, as: .description) {
            """
            [limit=\(expectedLimit), offset=\(expectedOffset)]
            """
        }
    }
}

fileprivate struct Req: PaginatedRequest {
    typealias Output = String

    var path: String = "/path"
    var headerFields: HTTPFields = [:]

    var offset: Int
    var limit: Int
}
