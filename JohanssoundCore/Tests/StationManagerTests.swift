import XCTest
@testable import JohanssoundCore

/// Covers the multi-station ``StationManager`` API added in Task 3.5:
/// list mutation (create/rename/delete), slug-collision handling, and
/// persistence round-tripping through ``StationStore``.
@MainActor
final class StationManagerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("johanssound-stations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root = tempRoot {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    private func makePlaylist(name: String) -> Playlist {
        Playlist(name: name, folder: nil, tracks: [], children: [], kind: .folder)
    }

    func testCreateAppendsToList() {
        let manager = StationManager()
        XCTAssertTrue(manager.stations.isEmpty)

        let a = manager.create(from: makePlaylist(name: "A"))
        let b = manager.create(from: makePlaylist(name: "B"))

        XCTAssertEqual(manager.stations.count, 2)
        XCTAssertEqual(manager.stations[0].id, a.id)
        XCTAssertEqual(manager.stations[1].id, b.id)
    }

    func testRenameUpdatesNameAndSlug() {
        let manager = StationManager()
        let station = manager.create(from: makePlaylist(name: "Jazz"))
        XCTAssertEqual(station.slug, "radio-based-on-jazz")

        manager.rename(station.id, to: "Midnight Mood")
        XCTAssertEqual(manager.stations[0].name, "Midnight Mood")
        XCTAssertEqual(manager.stations[0].slug, "midnight-mood")
    }

    func testRenameEmptyIsIgnored() {
        let manager = StationManager()
        let station = manager.create(from: makePlaylist(name: "A"))
        manager.rename(station.id, to: "   ")
        XCTAssertEqual(manager.stations[0].name, station.name)
    }

    func testDeleteRemovesStation() {
        let manager = StationManager()
        let a = manager.create(from: makePlaylist(name: "A"))
        let b = manager.create(from: makePlaylist(name: "B"))

        manager.delete(a.id)
        XCTAssertEqual(manager.stations.count, 1)
        XCTAssertEqual(manager.stations[0].id, b.id)
    }

    func testEnsureUniqueSlugAppendsNumberOnCollision() {
        let manager = StationManager()
        // Two playlists with the same name would yield the same slug —
        // manager must bump the second one.
        _ = manager.create(from: makePlaylist(name: "Jazz"))
        let second = manager.create(from: makePlaylist(name: "Jazz"))

        XCTAssertEqual(manager.stations.count, 2)
        XCTAssertNotEqual(manager.stations[0].slug, manager.stations[1].slug)
        // The bumped station's name carries the disambiguator.
        XCTAssertTrue(second.name.contains("(2)"))
    }

    func testRenameDoesNotCollideWithSelf() {
        let manager = StationManager()
        let station = manager.create(from: makePlaylist(name: "Jazz"))
        // Renaming to the current name (or a name that derives the same
        // slug as the current station) must not trigger the disambiguator.
        manager.rename(station.id, to: "Jazz Radio")
        XCTAssertEqual(manager.stations[0].name, "Jazz Radio")
        XCTAssertFalse(manager.stations[0].name.contains("("))
    }

    func testStationForSlugFindsMatch() {
        let manager = StationManager()
        let a = manager.create(from: makePlaylist(name: "Jazz"))
        _ = manager.create(from: makePlaylist(name: "Blues"))

        XCTAssertEqual(manager.station(forSlug: a.slug)?.id, a.id)
        XCTAssertNil(manager.station(forSlug: "nonexistent"))
    }

    func testPersistenceRoundTrip() {
        let first = StationManager()
        first.setStorage(root: tempRoot)
        let a = first.create(from: makePlaylist(name: "A"))
        let b = first.create(from: makePlaylist(name: "B"))

        // Build a fresh manager pointed at the same folder and verify the
        // list came back verbatim.
        let second = StationManager()
        second.setStorage(root: tempRoot)
        XCTAssertEqual(second.stations.count, 2)
        XCTAssertEqual(second.stations[0].id, a.id)
        XCTAssertEqual(second.stations[1].id, b.id)
    }

    func testPersistenceAfterRenameAndDelete() {
        let first = StationManager()
        first.setStorage(root: tempRoot)
        let a = first.create(from: makePlaylist(name: "A"))
        let b = first.create(from: makePlaylist(name: "B"))
        first.rename(a.id, to: "Renamed A")
        first.delete(b.id)

        let second = StationManager()
        second.setStorage(root: tempRoot)
        XCTAssertEqual(second.stations.count, 1)
        XCTAssertEqual(second.stations[0].id, a.id)
        XCTAssertEqual(second.stations[0].name, "Renamed A")
    }

    func testSetStorageReplacesInMemoryList() {
        // Start with an in-memory-only manager and add a station — it
        // should survive in memory but NOT be persisted, so pointing at a
        // fresh empty folder resets the list to []. This guards the
        // "switching music folders" flow.
        let manager = StationManager()
        _ = manager.create(from: makePlaylist(name: "Ghost"))
        XCTAssertEqual(manager.stations.count, 1)

        manager.setStorage(root: tempRoot)
        XCTAssertEqual(manager.stations.count, 0)
    }
}
