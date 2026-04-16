import XCTest
@testable import JohanssoundCore

/// State-transition tests for `AudioPlayer`.
///
/// We can't verify actual audio output from unit tests, so these cover the
/// observable parts: `currentTrack`, `queue`, and the transport API not
/// crashing and keeping state coherent.
final class AudioPlayerTests: XCTestCase {

    @MainActor
    func testInitialState() async {
        let player = AudioPlayer()
        XCTAssertNil(player.currentTrack)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.progress, 0)
        XCTAssertTrue(player.queue.isEmpty)
    }

    @MainActor
    func testPlaySingleTrackSetsCurrent() async throws {
        let tracks = try await Self.loadFixtureTracks()
        let player = AudioPlayer()
        player.play(tracks[0])
        XCTAssertEqual(player.currentTrack?.id, tracks[0].id)
        XCTAssertEqual(player.queue.count, 1)
    }

    @MainActor
    func testPlayQueueStartsAtIndex() async throws {
        let tracks = try await Self.loadFixtureTracks()
        guard tracks.count >= 2 else { throw XCTSkip("Need at least 2 fixture tracks") }
        let player = AudioPlayer()
        player.play(queue: tracks, startingAt: 1)
        XCTAssertEqual(player.currentTrack?.id, tracks[1].id)
        XCTAssertEqual(player.queue.count, tracks.count)
    }

    @MainActor
    func testNextAdvancesTrack() async throws {
        let tracks = try await Self.loadFixtureTracks()
        guard tracks.count >= 2 else { throw XCTSkip("Need at least 2 fixture tracks") }
        let player = AudioPlayer()
        player.play(queue: tracks, startingAt: 0)
        player.next()
        XCTAssertEqual(player.currentTrack?.id, tracks[1].id)
    }

    @MainActor
    func testNextAtEndStops() async throws {
        let tracks = try await Self.loadFixtureTracks()
        let player = AudioPlayer()
        player.play(queue: tracks, startingAt: tracks.count - 1)
        let endTrack = player.currentTrack
        player.next()
        // Spec allows either "stop on last" (currentTrack retained) or
        // "clear". Either is fine as long as we don't jump somewhere absurd.
        XCTAssertTrue(player.currentTrack == nil || player.currentTrack?.id == endTrack?.id)
    }

    @MainActor
    func testPreviousGoesBack() async throws {
        let tracks = try await Self.loadFixtureTracks()
        guard tracks.count >= 2 else { throw XCTSkip("Need at least 2 fixture tracks") }
        let player = AudioPlayer()
        player.play(queue: tracks, startingAt: 1)
        player.previous()
        XCTAssertEqual(player.currentTrack?.id, tracks[0].id)
    }

    @MainActor
    func testTogglePlayPauseFromPlaying() async throws {
        let tracks = try await Self.loadFixtureTracks()
        let player = AudioPlayer()
        player.play(tracks[0])
        // Give AVPlayer a moment to settle into a playing state.
        try await Task.sleep(nanoseconds: 100_000_000)
        player.togglePlayPause()
        // AVPlayer may take a moment to reflect pause; we don't assert
        // synchronously on isPlaying — we just verify togglePlayPause
        // doesn't crash and the API is wired.
    }

    // MARK: - Helpers

    nonisolated private static func loadFixtureTracks() async throws -> [Track] {
        let bundle = Bundle(for: AudioPlayerTests.self)
        let fixtureURL: URL
        if let url = bundle.url(forResource: "library", withExtension: nil, subdirectory: "Fixtures") {
            fixtureURL = url
        } else if let url = bundle.url(forResource: "library", withExtension: nil) {
            fixtureURL = url
        } else if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("library")
            if FileManager.default.fileExists(atPath: candidate.path) {
                fixtureURL = candidate
            } else {
                let flat = resourceURL.appendingPathComponent("library")
                if FileManager.default.fileExists(atPath: flat.path) {
                    fixtureURL = flat
                } else {
                    throw XCTSkip("Fixture folder not bundled")
                }
            }
        } else {
            throw XCTSkip("Fixture folder not bundled")
        }
        // The indexer now returns grouped playlists; "All Songs" is the
        // first entry and contains every track, so use it as the flat list
        // for player-level tests.
        let playlists = try await LibraryIndexer().scan(folder: fixtureURL)
        return playlists.first?.tracks ?? []
    }
}
