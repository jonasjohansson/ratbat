import XCTest
@testable import JohanssoundCore

/// Covers the Task 3.1 slice: building a ``Station`` from a playlist,
/// verifying the auto-name / seed propagation, and asserting that
/// ``StationManager`` swaps in a new active station on creation. Shuffle
/// coverage is probabilistic — with 30 tracks the chance of identical
/// orderings across two independent shuffles is ~1 / 30! which is well
/// below any flaky-test threshold.
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

    @MainActor
    func testStationManagerCreate() {
        let manager = StationManager()
        XCTAssertNil(manager.activeStation)
        let playlist = Playlist(
            name: "P",
            folder: nil,
            tracks: [],
            children: [],
            kind: .folder
        )
        manager.createStation(from: playlist)
        XCTAssertNotNil(manager.activeStation)
        XCTAssertEqual(
            manager.activeStation?.seed,
            .playlist(sourceID: playlist.id, sourceName: "P")
        )
        XCTAssertEqual(manager.activeStation?.name, "Radio based on P")
    }
}
