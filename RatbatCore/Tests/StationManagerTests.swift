import XCTest
@testable import RatbatCore

/// Covers the multi-station ``StationManager`` API added in Task 3.5:
/// list mutation (create/rename/delete), slug-collision handling, and
/// persistence round-tripping through ``StationStore``. The web-control
/// pass added the slug lifecycle closures (``StationManager/slugDidChange``,
/// ``StationManager/slugWasDeleted``) and the interim
/// ``StationManager/updateExploration(_:to:)`` setter — covered at the
/// bottom of this file.
@MainActor
final class StationManagerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratbat-stations-\(UUID().uuidString)")
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

    // MARK: - Slug lifecycle closures

    func testRenameFiresSlugDidChangeWithOldAndNewSlugs() {
        let manager = StationManager()
        let station = manager.create(from: makePlaylist(name: "Jazz"))
        var observed: (old: String, new: String)?
        manager.slugDidChange = { observed = (old: $0, new: $1) }

        manager.rename(station.id, to: "Midnight Mood")
        XCTAssertEqual(observed?.old, "radio-based-on-jazz")
        XCTAssertEqual(observed?.new, "midnight-mood")
    }

    func testRenameWithUnchangedSlugDoesNotFireSlugDidChange() {
        let manager = StationManager()
        let station = manager.create(from: makePlaylist(name: "Jazz"))
        manager.rename(station.id, to: "Jazz Radio")

        var fired = false
        manager.slugDidChange = { _, _ in fired = true }
        // "Jazz Radio!" is a different name but derives the same slug —
        // slug-keyed membership is still valid, so no re-key signal.
        manager.rename(station.id, to: "Jazz Radio!")

        XCTAssertEqual(manager.stations[0].name, "Jazz Radio!")
        XCTAssertFalse(fired)
    }

    func testDeleteFiresSlugWasDeleted() {
        let manager = StationManager()
        let station = manager.create(from: makePlaylist(name: "Jazz"))

        // Simulate the RootView wiring contract: the closure clears the
        // deleted slug from slug-keyed membership (auto-start / last-live
        // in production; a plain set here).
        var membership: Set<String> = [station.slug]
        manager.slugWasDeleted = { membership.remove($0) }

        manager.delete(station.id)
        XCTAssertTrue(membership.isEmpty)
    }

    func testDeleteUnknownIdDoesNotFireSlugWasDeleted() {
        let manager = StationManager()
        _ = manager.create(from: makePlaylist(name: "Jazz"))

        var fired = false
        manager.slugWasDeleted = { _ in fired = true }
        manager.delete(UUID())
        XCTAssertFalse(fired)
    }

    // MARK: - Exploration

    func testUpdateExplorationClampsAndPreservesIdentity() {
        let manager = StationManager()
        let station = manager.createLastFM(LastFMStationConfig(
            name: "Deep Cuts",
            query: FacetedQuery(genreTags: ["jazz"]),
            exploration: 0.5
        ))
        guard case .lastFM(let originalConfig) = station.kind else {
            return XCTFail("expected a Last.fm station")
        }

        let raised = manager.updateExploration(station.id, to: 1.7)
        XCTAssertEqual(raised?.id, station.id)
        guard case .lastFM(let raisedConfig) = raised?.kind else {
            return XCTFail("expected the station to stay Last.fm-backed")
        }
        XCTAssertEqual(raisedConfig.exploration, 1.0)
        // Config id keys HistoryStore dedup/affinity — must survive edits.
        XCTAssertEqual(raisedConfig.id, originalConfig.id)

        let lowered = manager.updateExploration(station.id, to: -3)
        guard case .lastFM(let loweredConfig) = lowered?.kind else {
            return XCTFail("expected the station to stay Last.fm-backed")
        }
        XCTAssertEqual(loweredConfig.exploration, 0.0)
    }

    func testUpdateExplorationNoOpsOnNonLastFMKinds() {
        let manager = StationManager()
        let playlistStation = manager.create(from: makePlaylist(name: "Fixed"))
        let ntsStation = manager.createNTS(NTSStationConfig(
            name: "Ambient",
            query: FacetedQuery(genreTags: ["ambient"])
        ))

        XCTAssertNil(manager.updateExploration(playlistStation.id, to: 0.5))
        XCTAssertNil(manager.updateExploration(ntsStation.id, to: 0.5))
        XCTAssertNil(manager.updateExploration(UUID(), to: 0.5))
        // The catalogue is untouched — answering nil is a true no-op.
        XCTAssertEqual(manager.stations[0].kind, playlistStation.kind)
        XCTAssertEqual(manager.stations[1].kind, ntsStation.kind)
    }
}
