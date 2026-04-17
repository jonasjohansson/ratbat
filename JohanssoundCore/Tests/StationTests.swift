import XCTest
@testable import JohanssoundCore

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
        XCTAssertEqual(
            station.seed,
            .playlist(sourceID: playlist.id, sourceName: playlist.name)
        )
    }

    func testStationShufflesQueue() {
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
        let s1 = Station.from(playlist: playlist)
        let s2 = Station.from(playlist: playlist)
        // Both queues are permutations of the same tracks…
        XCTAssertEqual(Set(s1.queue.map(\.id)), Set(tracks.map(\.id)))
        XCTAssertEqual(Set(s2.queue.map(\.id)), Set(tracks.map(\.id)))
        // …but their orderings should differ. With 30! possible orderings
        // this is effectively deterministic.
        XCTAssertNotEqual(s1.queue.map(\.id), s2.queue.map(\.id))
    }

    func testStationSlugIsUrlSafe() {
        let station = Station(
            name: "Radio based on Late Night!",
            seed: .manual,
            queue: []
        )
        XCTAssertEqual(station.slug, "radio-based-on-late-night")
    }

    func testStationSlugTransliteratesDiacritics() {
        let station = Station(name: "Äventyr Mix", seed: .manual, queue: [])
        XCTAssertEqual(station.slug, "aventyr-mix")
    }

    func testStationSlugHandlesEmptyName() {
        // All-emoji / all-punctuation names fall back to a uuid-prefix
        // slug so the route is still valid.
        let station = Station(name: "🎶🎶", seed: .manual, queue: [])
        XCTAssertTrue(station.slug.hasPrefix("station-"))
        XCTAssertEqual(station.slug.count, "station-".count + 8)
    }

    func testStationSlugCollapsesMultipleSeparators() {
        let station = Station(name: "A  ---  B__C", seed: .manual, queue: [])
        XCTAssertEqual(station.slug, "a-b-c")
    }
}
