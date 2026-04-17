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

    @MainActor
    func testBatchIsActiveUntilFinishedAtSet() {
        var batch = DownloadService.Batch(
            id: UUID(),
            url: URL(string: "https://example.com")!,
            destination: URL(fileURLWithPath: "/tmp"),
            jobs: [],
            startedAt: Date()
        )
        XCTAssertTrue(batch.isActive)
        batch.finishedAt = Date()
        XCTAssertFalse(batch.isActive)
    }

    @MainActor
    func testCompletedCountReflectsDoneJobs() {
        let jobs: [DownloadService.Job] = [
            .init(id: UUID(), title: "A", status: .done),
            .init(id: UUID(), title: "B", status: .downloading),
            .init(id: UUID(), title: "C", status: .done),
            .init(id: UUID(), title: "D", status: .failed("x"))
        ]
        let batch = DownloadService.Batch(
            id: UUID(),
            url: URL(string: "https://example.com")!,
            destination: URL(fileURLWithPath: "/tmp"),
            jobs: jobs,
            startedAt: Date()
        )
        XCTAssertEqual(batch.completedCount, 2)
    }
}
#endif
