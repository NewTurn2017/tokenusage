import XCTest
@testable import TokenUsageCore

final class FoundationTests: XCTestCase {
    func testCoreFoundationCompiles() {
        XCTAssertEqual(2 + 2, 4)
    }
}
