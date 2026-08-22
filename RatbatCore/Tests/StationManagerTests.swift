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

    // MARK: - station(id:)

    func testStationByIDFindsMatch() {
        let manager = StationManager()
        let a = manager.create(from: makePlaylist(name: "Jazz"))
        _ = manager.create(from: makePlaylist(name: "Blues"))

        XCTAssertEqual(manager.station(id: a.id)?.id, a.id)
        XCTAssertNil(manager.station(id: UUID()))
    }

    // MARK: - Validated creation (the single surface)

    func testCreateStationFallsBackToSuggestedNameAndUniquifies() throws {
        let manager = StationManager()
        let query = FacetedQuery(genreTags: ["techno"])

        let first = try manager.createStation(
            .nts(query: query, shufflePool: true), name: nil
        )
        XCTAssertEqual(first.name, query.suggestedName)

        // A second nameless creation with the same query collides on slug
        // and gets the desktop's "(2)" bump, exactly like the old creators.
        let second = try manager.createStation(
            .nts(query: query, shufflePool: true), name: nil
        )
        XCTAssertTrue(second.name.contains("(2)"), "got: \(second.name)")
        XCTAssertNotEqual(first.slug, second.slug)
    }

    /// Every GENERATIVE kind — Library Radio is exempt by design (empty
    /// tags = whole library) and covered in its own matrix below.
    func testCreateStationThrowsOnEmptyTagsForEveryKind() {
        let manager = StationManager()
        let empty = FacetedQuery(genreTags: [])
        let drafts: [StationDraft] = [
            .nts(query: empty, shufflePool: true),
            .lastFM(query: empty, shufflePool: true, exploration: 0.25),
            .bandcamp(query: empty, sort: .date, shufflePool: true)
        ]
        for draft in drafts {
            XCTAssertThrowsError(try manager.createStation(draft, name: "Named")) { error in
                XCTAssertEqual(
                    error as? StationManager.StationEditError, .emptyGenreTags
                )
            }
        }
        XCTAssertTrue(manager.stations.isEmpty, "a refused create must leave nothing behind")
    }

    func testCreateStationThrowsOnBlankProvidedName() {
        let manager = StationManager()
        // A *provided* name that trims to nothing is an error — the
        // caller typed something and silently ignoring it would be worse.
        // (No name at all falls back to suggestedName instead.)
        XCTAssertThrowsError(try manager.createStation(
            .nts(query: FacetedQuery(genreTags: ["dub"]), shufflePool: true),
            name: "   "
        )) { error in
            XCTAssertEqual(error as? StationManager.StationEditError, .emptyName)
        }
        XCTAssertTrue(manager.stations.isEmpty)
    }

    func testCreateStationCarriesTheDraftKnobs() throws {
        let manager = StationManager()
        let query = FacetedQuery(genreTags: ["jazz"])
        let station = try manager.createStation(
            .lastFM(query: query, shufflePool: false, exploration: 0.8),
            name: "Knobs"
        )
        guard case .lastFM(let config) = station.kind else {
            return XCTFail("expected a Last.fm station")
        }
        XCTAssertEqual(config.query, query)
        XCTAssertFalse(config.shufflePool)
        XCTAssertEqual(config.exploration, 0.8)
    }

    // MARK: - applyUpdate

    private func makeGenerativeTrio(
        _ manager: StationManager
    ) -> (nts: Station, lastFM: Station, bandcamp: Station) {
        (
            manager.createNTS(NTSStationConfig(
                name: "NTS", query: FacetedQuery(genreTags: ["ambient"])
            )),
            manager.createLastFM(LastFMStationConfig(
                name: "LastFM", query: FacetedQuery(genreTags: ["jazz"])
            )),
            manager.createBandcamp(BandcampStationConfig(
                name: "Bandcamp", query: FacetedQuery(genreTags: ["techno"])
            ))
        )
    }

    /// The 225bb06 invariant, through the general editor: the station id
    /// AND its config id survive an update — the config id keys
    /// HistoryStore dedup and taste affinity, so letting either move
    /// would orphan everything the station ever played.
    func testApplyUpdatePreservesStationAndConfigIdentity() throws {
        let manager = StationManager()
        let trio = makeGenerativeTrio(manager)
        let newQuery = FacetedQuery(genreTags: ["drone", "dub"], yearMin: 1990)

        for original in [trio.nts, trio.lastFM, trio.bandcamp] {
            let updated = try manager.applyUpdate(
                original.id, StationUpdate(query: newQuery)
            )
            XCTAssertEqual(updated.id, original.id, "station id must not move")
            let configID: UUID? = {
                switch updated.kind {
                case .playlist: return nil
                case .nts(let c): return c.id
                case .lastFM(let c): return c.id
                case .bandcamp(let c): return c.id
                case .libraryRadio(let c): return c.id
                }
            }()
            XCTAssertEqual(configID, original.id, "config id keys history — it must not move")
        }
    }

    func testApplyUpdateRenameFiresSlugDidChangeAndUniquifies() throws {
        let manager = StationManager()
        _ = manager.create(from: makePlaylist(name: "Jazz"))
        let station = manager.createNTS(NTSStationConfig(
            name: "Ambient", query: FacetedQuery(genreTags: ["ambient"])
        ))

        var observed: (old: String, new: String)?
        manager.slugDidChange = { observed = (old: $0, new: $1) }

        // Renaming onto an existing station's slug gets the "(2)" bump —
        // same collision handling as rename(_:to:), through one persist.
        let updated = try manager.applyUpdate(
            station.id, StationUpdate(name: "Radio based on Jazz")
        )
        XCTAssertEqual(updated.name, "Radio based on Jazz (2)")
        XCTAssertEqual(observed?.old, "ambient")
        XCTAssertEqual(observed?.new, "radio-based-on-jazz-2")
    }

    func testApplyUpdateErrorCases() {
        let manager = StationManager()
        let playlist = manager.create(from: makePlaylist(name: "Fixed"))
        let trio = makeGenerativeTrio(manager)
        let query = FacetedQuery(genreTags: ["dub"])

        func assertThrows(
            _ id: Station.ID, _ update: StationUpdate,
            _ expected: StationManager.StationEditError,
            line: UInt = #line
        ) {
            XCTAssertThrowsError(try manager.applyUpdate(id, update)) { error in
                XCTAssertEqual(
                    error as? StationManager.StationEditError, expected,
                    line: line
                )
            }
        }

        assertThrows(UUID(), StationUpdate(name: "New"), .unknownStation)
        assertThrows(playlist.id, StationUpdate(query: query), .kindHasNoQuery)
        assertThrows(playlist.id, StationUpdate(shufflePool: false), .wrongKind)
        assertThrows(
            trio.nts.id,
            StationUpdate(query: FacetedQuery(genreTags: [])),
            .emptyGenreTags
        )
        assertThrows(trio.nts.id, StationUpdate(name: "  "), .emptyName)
        assertThrows(trio.nts.id, StationUpdate(sort: .pop), .wrongKind)
        assertThrows(trio.bandcamp.id, StationUpdate(exploration: 0.5), .wrongKind)
    }

    /// Validation runs before any mutation — a refused update leaves the
    /// station byte-for-byte as it was, even when *some* of its fields
    /// were individually valid.
    func testApplyUpdateValidatesBeforeMutating() {
        let manager = StationManager()
        let trio = makeGenerativeTrio(manager)
        let before = manager.stations

        // Valid rename + invalid empty-tags query in one update: the
        // rename must not land.
        XCTAssertThrowsError(try manager.applyUpdate(
            trio.nts.id,
            StationUpdate(name: "Half Applied", query: FacetedQuery(genreTags: []))
        ))
        XCTAssertEqual(manager.stations, before, "a refused update must change nothing")
    }

    func testApplyUpdateClampsExplorationAndFlipsShufflePool() throws {
        let manager = StationManager()
        let trio = makeGenerativeTrio(manager)

        let updated = try manager.applyUpdate(
            trio.lastFM.id,
            StationUpdate(exploration: 2.5, shufflePool: false)
        )
        guard case .lastFM(let config) = updated.kind else {
            return XCTFail("expected the station to stay Last.fm-backed")
        }
        XCTAssertEqual(config.exploration, 1.0, "exploration clamps to [0, 1]")
        XCTAssertFalse(config.shufflePool)

        let sorted = try manager.applyUpdate(
            trio.bandcamp.id, StationUpdate(sort: .pop)
        )
        guard case .bandcamp(let bandcampConfig) = sorted.kind else {
            return XCTFail("expected the station to stay Bandcamp-backed")
        }
        XCTAssertEqual(bandcampConfig.sort, .pop)
    }

    /// The edit has to survive a relaunch — applyUpdate persists in the
    /// same tick, like every other mutation here.
    func testApplyUpdatePersists() throws {
        let first = StationManager()
        first.setStorage(root: tempRoot)
        let station = first.createNTS(NTSStationConfig(
            name: "Before", query: FacetedQuery(genreTags: ["ambient"])
        ))
        let newQuery = FacetedQuery(genreTags: ["drone"], yearMax: 1999)
        _ = try first.applyUpdate(
            station.id, StationUpdate(name: "After", query: newQuery)
        )

        let second = StationManager()
        second.setStorage(root: tempRoot)
        XCTAssertEqual(second.stations.count, 1)
        XCTAssertEqual(second.stations[0].id, station.id)
        XCTAssertEqual(second.stations[0].name, "After")
        XCTAssertEqual(second.stations[0].ntsConfig?.query, newQuery)
    }

    // MARK: - Library Radio (S4)

    /// Library Radio is the deliberate exception to the one-tag rule: an
    /// empty filter means "the whole library". The name falls back to
    /// "Library Radio" rather than suggestedName's generic "New Station",
    /// and a stored `excludeOwnedLibrary: true` — a station configured to
    /// play nothing, since every candidate is owned — is normalized to
    /// false at the write surface.
    func testCreateLibraryRadioAllowsEmptyTagsAndNormalizesTheQuery() throws {
        let manager = StationManager()
        let station = try manager.createStation(
            .libraryRadio(
                query: FacetedQuery(genreTags: [], excludeOwnedLibrary: true),
                shufflePool: true
            ),
            name: nil
        )
        XCTAssertEqual(station.name, "Library Radio")
        guard case .libraryRadio(let config) = station.kind else {
            return XCTFail("expected a Library Radio station")
        }
        XCTAssertEqual(config.id, station.id, "config id doubles as station id (history invariant)")
        XCTAssertTrue(config.query.genreTags.isEmpty)
        XCTAssertFalse(config.query.excludeOwnedLibrary, "the meaningless flag is normalized off")

        // Tagged creates keep the suggested-name behavior of the siblings.
        let tagged = try manager.createStation(
            .libraryRadio(query: FacetedQuery(genreTags: ["ambient"]), shufflePool: false),
            name: nil
        )
        XCTAssertEqual(tagged.name, FacetedQuery(genreTags: ["ambient"]).suggestedName)
        XCTAssertEqual(tagged.libraryRadioConfig?.shufflePool, false)
    }

    /// The applyUpdate matrix for the new kind, per the wire contract:
    /// `name` / `query` (empty tags allowed) / `shufflePool` apply;
    /// `exploration` and `sort` are `wrongKind`; identity is preserved
    /// and the normalization rides every query write.
    func testApplyUpdateLibraryRadioMatrix() throws {
        let manager = StationManager()
        let station = try manager.createStation(
            .libraryRadio(query: FacetedQuery(genreTags: ["techno"]), shufflePool: true),
            name: "Mine"
        )

        // The whole-library edit: clearing every tag is a VALID update
        // here (the emptyGenreTags carve-out), and the flag normalizes.
        let cleared = try manager.applyUpdate(station.id, StationUpdate(
            name: "Everything",
            query: FacetedQuery(genreTags: [], excludeOwnedLibrary: true),
            shufflePool: false
        ))
        XCTAssertEqual(cleared.id, station.id)
        guard case .libraryRadio(let config) = cleared.kind else {
            return XCTFail("kind must not change")
        }
        XCTAssertEqual(cleared.name, "Everything")
        XCTAssertTrue(config.query.genreTags.isEmpty)
        XCTAssertFalse(config.query.excludeOwnedLibrary)
        XCTAssertFalse(config.shufflePool)

        // The knobs this kind does not have answer wrongKind, exactly as
        // the wire contract promises (exploration/sort → 409 upstream).
        XCTAssertThrowsError(try manager.applyUpdate(
            station.id, StationUpdate(exploration: 0.5)
        )) { error in
            XCTAssertEqual(error as? StationManager.StationEditError, .wrongKind)
        }
        XCTAssertThrowsError(try manager.applyUpdate(
            station.id, StationUpdate(sort: .pop)
        )) { error in
            XCTAssertEqual(error as? StationManager.StationEditError, .wrongKind)
        }
    }

    /// The new kind persists and reloads like every sibling — under
    /// store version 1, which must not move (risk R2).
    func testLibraryRadioPersistsThroughTheManager() throws {
        let first = StationManager()
        first.setStorage(root: tempRoot)
        let station = try first.createStation(
            .libraryRadio(query: FacetedQuery(genreTags: ["dub"]), shufflePool: true),
            name: "Reloaded"
        )

        let second = StationManager()
        second.setStorage(root: tempRoot)
        XCTAssertEqual(second.stations.count, 1)
        XCTAssertEqual(second.stations[0].id, station.id)
        XCTAssertEqual(second.stations[0].libraryRadioConfig?.query.genreTags, ["dub"])
    }
}
