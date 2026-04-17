#if os(macOS)
import XCTest
@testable import RatbatCore

/// Covers ``TrackSource`` + ``PlaylistSource`` semantics. ``NTSSource``
/// needs a live NTS scrape + yt-dlp resolver to do anything meaningful,
/// so it's exercised end-to-end manually rather than unit-tested here.
final class TrackSourceTests: XCTestCase {

    func testPlaylistSourceYieldsTracksInOrder() async throws {
        let a = Track(url: URL(fileURLWithPath: "/a.m4a"), title: "A", artist: "X", album: "L", duration: 100)
        let b = Track(url: URL(fileURLWithPath: "/b.m4a"), title: "B", artist: "X", album: "L", duration: 100)
        let source = PlaylistSource(tracks: [a, b])
        let first = try await source.nextURL()
        XCTAssertEqual(first?.title, "A")
        let second = try await source.nextURL()
        XCTAssertEqual(second?.title, "B")
    }

    func testPlaylistSourceLoops() async throws {
        let a = Track(url: URL(fileURLWithPath: "/a.m4a"), title: "A", artist: "X", album: "L", duration: 100)
        let source = PlaylistSource(tracks: [a])
        _ = try await source.nextURL()
        let wrapped = try await source.nextURL()
        XCTAssertEqual(wrapped?.title, "A", "single-track queue should loop")
    }

    func testPlaylistSourceEmptyReturnsNil() async throws {
        let source = PlaylistSource(tracks: [])
        let item = try await source.nextURL()
        XCTAssertNil(item)
    }

    func testTrackSourceItemFieldsPopulate() {
        let item = TrackSourceItem(
            url: URL(fileURLWithPath: "/x.m4a"),
            artist: "Ar", title: "Ti", historyID: 42
        )
        XCTAssertEqual(item.artist, "Ar")
        XCTAssertEqual(item.title, "Ti")
        XCTAssertEqual(item.historyID, 42)
    }
}
#endif
