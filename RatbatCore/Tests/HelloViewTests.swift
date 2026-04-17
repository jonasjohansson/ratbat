import XCTest
@testable import RatbatCore

final class HelloViewTests: XCTestCase {
    func testHelloViewExists() {
        let view = HelloView()
        XCTAssertNotNil(view)
    }
}
