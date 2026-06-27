import XCTest
@testable import RatbatCore

/// Covers ``Station`` value semantics — construction from a playlist, auto-
/// naming, shuffle behaviour, and slug derivation. Shuffle coverage is
/// probabilistic: with 30 tracks, two independent shuffles colliding is
/// ~1/30! which is well below any flaky-test threshold.
final class StationTests: XCTestCase {
    func testStationFromPlaylistUsesSameTracks() {
        let track = Track(
            url: URL(fileURLWithPath: "/fake/a.m4a"),
            title: "A",
            artist: "X",
            album: "L",
            duration: 120
        )
        let playlist = Playlist(
            name: "My Playlist",
            folder: nil,
            tracks: [track],
            children: [],
            kind: .folder
        )
        let station = Station.from(playlist: playlist)
        XCTAssertEqual(station.queue.count, 1)
        XCTAssertEqual(station.queue[0].id, track.id)
        XCTAssertEqual(station.name, "Radio based on My Playlist")
        // The Kind-based model: the playlist queue IS the kind's payload.
        if case let .playlist(queue) = station.kind {
            XCTAssertEqual(queue.count, 1)
        } else {
            XCTFail("Expected playlist kind, got \(station.kind)")
        }
    }

    func testStationFromPlaylistPreservesNaturalOrder() {
        // Station.from(playlist:) stores the queue in natural playlist
        // order; shuffling happens in PlaylistSource on every broadcast
        // start (covered by TrackSourceTests). Freezing a single shuffle
        // here was the "always starts on the same song" bug.
        let tracks = (0..<30).map {
            Track(
                url: URL(fileURLWithPath: "/fake/\($0).m4a"),
                title: "T\($0)",
                artist: "X",
                album: "L",
                duration: 120
            )
        }
        let playlist = Playlist(
            name: "P",
            folder: nil,
            tracks: tracks,
            children: [],
            kind: .folder
        )
        let station = Station.from(playlist: playlist)
        XCTAssertEqual(station.queue.map(\.id), tracks.map(\.id),
                       "queue should preserve the playlist's natural order")
    }

    func testStationSlugIsUrlSafe() {
        let station = Station(
            name: "Radio based on Late Night!",
            kind: .playlist(queue: [])
        )
        XCTAssertEqual(station.slug, "radio-based-on-late-night")
    }

    func testStationSlugTransliteratesDiacritics() {
        let station = Station(name: "Äventyr Mix", kind: .playlist(queue: []))
        XCTAssertEqual(station.slug, "aventyr-mix")
    }

    func testStationSlugHandlesEmptyName() {
        // All-emoji / all-punctuation names fall back to a uuid-prefix
        // slug so the route is still valid.
        let station = Station(name: "🎶🎶", kind: .playlist(queue: []))
        XCTAssertTrue(station.slug.hasPrefix("station-"))
        XCTAssertEqual(station.slug.count, "station-".count + 8)
    }

    func testStationSlugCollapsesMultipleSeparators() {
        let station = Station(name: "A  ---  B__C", kind: .playlist(queue: []))
        XCTAssertEqual(station.slug, "a-b-c")
    }
}
