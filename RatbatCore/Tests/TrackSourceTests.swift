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
        let source = PlaylistSource(tracks: [a, b], shuffle: false)
        let first = try await source.nextURL()
        XCTAssertEqual(first?.title, "A")
        let second = try await source.nextURL()
        XCTAssertEqual(second?.title, "B")
    }

    func testPlaylistSourceLoops() async throws {
        let a = Track(url: URL(fileURLWithPath: "/a.m4a"), title: "A", artist: "X", album: "L", duration: 100)
        let source = PlaylistSource(tracks: [a], shuffle: false)
        _ = try await source.nextURL()
        let wrapped = try await source.nextURL()
        XCTAssertEqual(wrapped?.title, "A", "single-track queue should loop")
    }

    /// Shuffling yields every track exactly once per pass (a permutation,
    /// never a dropped or duplicated track within a lap).
    func testPlaylistSourceShuffleIsPermutationPerPass() async throws {
        let tracks = (0..<12).map {
            Track(url: URL(fileURLWithPath: "/\($0).m4a"), title: "T\($0)", artist: "X", album: "L", duration: 100)
        }
        let source = PlaylistSource(tracks: tracks)
        var seen: [String] = []
        for _ in tracks.indices { seen.append(try await source.nextURL()!.title!) }
        XCTAssertEqual(Set(seen).count, tracks.count, "each track should appear once per pass")
    }

    /// Two freshly-created sources over the same queue should (very
    /// likely) open on a different first track — the regression this
    /// fixes was every start replaying the same frozen order.
    func testPlaylistSourceVariesStartAcrossInstances() async throws {
        let tracks = (0..<30).map {
            Track(url: URL(fileURLWithPath: "/\($0).m4a"), title: "T\($0)", artist: "X", album: "L", duration: 100)
        }
        var firsts: Set<String> = []
        for _ in 0..<8 {
            let source = PlaylistSource(tracks: tracks)
            firsts.insert(try await source.nextURL()!.title!)
        }
        XCTAssertGreaterThan(firsts.count, 1, "different starts should open on different tracks")
    }

    /// A track should not immediately repeat across the loop seam.
    func testPlaylistSourceNoRepeatAcrossSeam() async throws {
        let tracks = (0..<20).map {
            Track(url: URL(fileURLWithPath: "/\($0).m4a"), title: "T\($0)", artist: "X", album: "L", duration: 100)
        }
        let source = PlaylistSource(tracks: tracks)
        for _ in 0..<5 {
            var lap: [String] = []
            for _ in tracks.indices { lap.append(try await source.nextURL()!.title!) }
            let seam = try await source.nextURL()!.title!   // first of next lap
            XCTAssertNotEqual(lap.last, seam, "track must not repeat across the seam")
            // rewind bookkeeping: consume the rest of this lap so the next
            // outer iteration starts cleanly at a seam boundary again.
            for _ in 1..<tracks.count { _ = try await source.nextURL() }
        }
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
