import XCTest
@testable import RatbatCore

/// Covers ``LibraryRadioStationController``'s pool pipeline — the facet
/// filter (which facets a local file can honor and which are ignored),
/// taste scoring with the skip blacklist, the shared SelectionPlanner
/// stage with its audit rows, and the loop-forever refill contract —
/// plus ``LibraryRadioSource``'s TrackSource projection. Fixture tracks
/// are hand-constructed ``Track`` values (the LibraryIndexerTests
/// stance): the controller never opens a file, so nothing here needs
/// real audio on disk.
final class LibraryRadioControllerTests: XCTestCase {

    private var tempDBURL: URL!

    override func setUp() async throws {
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-radio-\(UUID()).db")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDBURL)
        try? FileManager.default.removeItem(at: tempDBURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempDBURL.appendingPathExtension("shm"))
    }

    // MARK: - Fixtures

    private func track(
        _ title: String,
        artist: String,
        genre: String? = nil,
        year: Int? = nil,
        duration: TimeInterval = 180
    ) -> Track {
        Track(
            url: URL(fileURLWithPath: "/fake/\(title).m4a"),
            title: title,
            artist: artist,
            album: "Album",
            duration: duration,
            year: year,
            genre: genre
        )
    }

    private func makeController(
        tracks: [Track],
        query: FacetedQuery = FacetedQuery(genreTags: []),
        shufflePool: Bool = false,
        history: HistoryStore? = nil,
        profile: TasteProfile = TasteProfile(),
        stationID: UUID = UUID(),
        policy: @escaping @Sendable () async -> SelectionPolicy = { .default },
        recordExclusions: (@Sendable ([SelectionExclusionRecord]) async -> Void)? = nil
    ) -> LibraryRadioStationController {
        LibraryRadioStationController(
            config: LibraryRadioStationConfig(
                id: stationID, name: "Test", query: query, shufflePool: shufflePool
            ),
            libraryTracks: { tracks },
            history: history,
            tasteProfile: profile,
            selectionPolicy: policy,
            recordExclusions: recordExclusions
        )
    }

    // MARK: - Facet filter (pure)

    func testTagFilterMatchesAnyAndAllModes() {
        let multi = track("Multi", artist: "A", genre: "Ambient; Downtempo")
        let single = track("Single", artist: "B", genre: "Ambient")
        let untagged = track("Untagged", artist: "C")

        let any = FacetedQuery(genreTags: ["downtempo"], tagMatch: .any)
        XCTAssertTrue(LibraryRadioStationController.matches(multi, query: any))
        XCTAssertFalse(LibraryRadioStationController.matches(single, query: any))
        // A file with no genre tag cannot prove membership under a tag
        // filter — excluded, not admitted-by-default.
        XCTAssertFalse(LibraryRadioStationController.matches(untagged, query: any))

        let all = FacetedQuery(genreTags: ["ambient", "downtempo"], tagMatch: .all)
        XCTAssertTrue(LibraryRadioStationController.matches(multi, query: all),
                      "multi-genre fields split on separators, so .all can succeed")
        XCTAssertFalse(LibraryRadioStationController.matches(single, query: all))
    }

    func testEmptyTagListMeansWholeLibrary() {
        let untagged = track("Untagged", artist: "C")
        XCTAssertTrue(LibraryRadioStationController.matches(
            untagged, query: FacetedQuery(genreTags: [])
        ), "no filter admits everything — that is the kind's default state")
    }

    func testEraFilterHonorsYearAndExcludesUntaggedFiles() {
        let nineties = track("Nine", artist: "A", year: 1994)
        let modern = track("Modern", artist: "B", year: 2019)
        let unknown = track("NoYear", artist: "C")

        let era = FacetedQuery(genreTags: [], yearMin: 1990, yearMax: 1999)
        XCTAssertTrue(LibraryRadioStationController.matches(nineties, query: era))
        XCTAssertFalse(LibraryRadioStationController.matches(modern, query: era))
        // "Honored where metadata allows": a file with no year tag can't
        // prove it belongs to the era, so it is excluded while a bound
        // is set — documented on LibraryRadioStationConfig.
        XCTAssertFalse(LibraryRadioStationController.matches(unknown, query: era))
    }

    func testRegionsAndPopularityAreIgnored() {
        // File metadata has no artist-country or listener count, so these
        // facets must not filter anything — a track matching every
        // honorable facet passes whatever they say.
        let t = track("Plain", artist: "A", genre: "Techno")
        let query = FacetedQuery(
            genreTags: ["techno"],
            regions: ["JP"],
            popularity: .deepCuts,
            excludeOwnedLibrary: true   // meaningless here too — all owned
        )
        XCTAssertTrue(LibraryRadioStationController.matches(t, query: query))
    }

    func testExcludedArtistsDropCaseInsensitively() {
        let t = track("Cut", artist: "Aphex Twin")
        let query = FacetedQuery(genreTags: [], excludedArtists: ["aphex twin"])
        XCTAssertFalse(LibraryRadioStationController.matches(t, query: query))
    }

    // MARK: - Pool: scoring + blacklist

    /// The taste ordering, end to end: candidates the profile favours
    /// (dominant library tag) rank first, and a 👎-blacklisted artist is
    /// dropped from the pool entirely rather than merely demoted.
    func testRefillRanksByTasteAndDropsSkippedArtists() async throws {
        let store = try await HistoryStore(databaseURL: tempDBURL)
        let stationID = UUID()

        let favourite = track("Fav", artist: "Alpha", genre: "Techno")
        let outlier = track("Odd", artist: "Beta", genre: "Polka")
        let banned = track("Bad", artist: "Gamma", genre: "Techno")

        // Library layer: techno dominates, so Alpha's tag score beats
        // Beta's. Extra techno tracks weight the tag without joining the
        // candidate pool (they're not in `tracks` below).
        let profile = TasteProfile()
        await profile.ingestLibrary([
            favourite, outlier, banned,
            track("W1", artist: "X", genre: "Techno"),
            track("W2", artist: "Y", genre: "Techno")
        ])

        // Behavioral layer: Gamma got the 👎 on this station.
        let rowID = try await store.record(station: stationID, artist: "Gamma", title: "Bad")
        try await store.markSkipped(id: rowID)

        let controller = makeController(
            tracks: [outlier, favourite, banned],
            history: store,
            profile: profile,
            stationID: stationID
        )
        try await controller.refillPool()
        let pool = await controller.poolSnapshot()

        XCTAssertEqual(pool.map(\.title), ["Fav", "Odd"],
                       "taste-ranked, skip-blacklisted artist gone")
    }

    /// The loop-forever contract: unlike the generative kinds there is
    /// no per-station dedup, so a two-track pool serves five tracks by
    /// refilling at the end of each lap instead of running dry.
    func testNextTrackLoopsAcrossRefills() async throws {
        let a = track("A", artist: "One")
        let b = track("B", artist: "Two")
        let controller = makeController(tracks: [a, b])

        var served: [String] = []
        for _ in 0..<5 {
            served.append(try await controller.nextTrack().title)
        }
        XCTAssertEqual(served, ["A", "B", "A", "B", "A"],
                       "deterministic laps with shufflePool off")
    }

    /// A filter that matches nothing is the one genuine end-of-supply:
    /// the controller throws and the source maps it to `nil` so the
    /// pipeline stands down cleanly.
    func testEmptyFilterResultThrowsEmptyPool() async {
        let controller = makeController(
            tracks: [track("A", artist: "One", genre: "Techno")],
            query: FacetedQuery(genreTags: ["jazz"])
        )
        do {
            _ = try await controller.nextTrack()
            XCTFail("expected emptyPool")
        } catch let error as LibraryRadioStationController.Error {
            XCTAssertEqual(error, .emptyPool)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - SelectionPolicy stage

    /// The shared planner runs while the pool is built: with the mix-set
    /// toggle ON a long track is removed AND an enforced audit row lands
    /// with this kind's sourceKind spelling; short tracks survive. This
    /// is the one source where the duration arm measures the exact file
    /// length rather than a listing's estimate.
    func testMixSetPolicyFiltersPoolAndRecordsAudit() async throws {
        let short = track("Short", artist: "One", duration: 200)
        let long = track("Marathon Mix", artist: "Two", duration: 2 * 60 * 60)

        // Actor-safe collector for the recorded rows.
        actor Sink {
            var rows: [SelectionExclusionRecord] = []
            func append(_ new: [SelectionExclusionRecord]) { rows.append(contentsOf: new) }
        }
        let sink = Sink()

        let controller = makeController(
            tracks: [short, long],
            policy: { SelectionPolicy(excludeMixSets: true) },
            recordExclusions: { rows in await sink.append(rows) }
        )
        try await controller.refillPool()

        let pool = await controller.poolSnapshot()
        XCTAssertEqual(pool.map(\.title), ["Short"], "the mix set is enforced out")

        let rows = await sink.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sourceKind, "libraryRadio")
        XCTAssertTrue(rows[0].enforced)
        XCTAssertEqual(rows[0].arm, SelectionArm.duration)
        XCTAssertEqual(rows[0].durationSource, "library",
                       "duration is the measured file length, not an estimate")
    }

    // MARK: - Source projection

    /// ``LibraryRadioSource`` publishes the PlaylistSource truth: owned
    /// file, `origin: .library`, tag metadata as explicit nils when
    /// empty, and the recorded play's history id riding along.
    func testSourceProjectsOwnedLibraryItems() async throws {
        let t = track("Mine", artist: "Alpha")
        let controller = makeController(tracks: [t])
        let source = LibraryRadioSource(
            controller: controller,
            recordPlay: { _, _, _ in 42 }
        )
        let maybeItem = try await source.nextURL()
        let item = try XCTUnwrap(maybeItem)
        XCTAssertEqual(item.origin, .library)
        XCTAssertTrue(item.isOwned, "a ♥ must record affinity, never re-copy an owned file")
        XCTAssertEqual(item.historyID, 42)
        XCTAssertEqual(item.artist, "Alpha")
        XCTAssertEqual(item.url, t.url)
    }

    /// End-of-supply maps to `nil` — "this station is over" — exactly
    /// like `poolExhausted` does for the generative sources.
    func testSourceMapsEmptyPoolToNil() async throws {
        let controller = makeController(
            tracks: [],
            query: FacetedQuery(genreTags: ["anything"])
        )
        let source = LibraryRadioSource(controller: controller)
        let item = try await source.nextURL()
        XCTAssertNil(item)
    }
}

extension LibraryRadioStationController.Error: Equatable {
    public static func == (
        lhs: LibraryRadioStationController.Error,
        rhs: LibraryRadioStationController.Error
    ) -> Bool {
        switch (lhs, rhs) {
        case (.emptyPool, .emptyPool): return true
        }
    }
}
