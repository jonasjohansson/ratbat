#if os(macOS)
import XCTest
@testable import RatbatCore

/// Pure-parser tests for `DownloadService`.
///
/// Subprocess/venv behaviour is not exercised here — that path depends on a
/// Python install, network access, and ffmpeg. We limit these tests to the
/// line-prefix parsers and the initial actor state, which are fast and
/// deterministic.
final class DownloadServiceTests: XCTestCase {
    func testParseMatchingExtractsTitle() {
        XCTAssertEqual(DownloadService.parseMatching("[MATCHING] Where Is My Mind"),
                       "Where Is My Mind")
    }

    func testParseFoundStripsURL() {
        XCTAssertEqual(DownloadService.parseFound("[FOUND] Where Is My Mind (https://music.youtube.com/watch?v=abc)"),
                       "Where Is My Mind")
    }

    func testParseFoundWithoutURL() {
        XCTAssertEqual(DownloadService.parseFound("[FOUND] Where Is My Mind"),
                       "Where Is My Mind")
    }

    func testParseNoMatchExtractsTitle() {
        XCTAssertEqual(DownloadService.parseNoMatch("[NO MATCH] Obscure Track"),
                       "Obscure Track")
    }

    func testParseMismatchReturnsNil() {
        XCTAssertNil(DownloadService.parseMatching("[FOUND] other"))
        XCTAssertNil(DownloadService.parseFound("random log"))
    }

    @MainActor
    func testInitialState() async {
        let svc = DownloadService()
        XCTAssertTrue(svc.batches.isEmpty)
        XCTAssertEqual(svc.setupState, .unknown)
    }
}
#endif
