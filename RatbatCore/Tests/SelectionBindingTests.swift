#if os(macOS)
import XCTest
@testable import RatbatCore

/// Tests that the two listener preferences are honoured AT SELECTION TIME
/// by each of the four sources, and — the defect class this slice exists to
/// avoid — that the policy is RE-READ at every pool refill rather than
/// snapshotted once when the pipeline starts.
///
/// No network: ``StubURLProtocol`` answers every NTS request from in-memory
/// JSON, and nothing here constructs a tunnel or a listener.
final class SelectionBindingTests: XCTestCase {

    // MARK: - The actor crossing: re-read at every refill

    /// The test the brief names explicitly: provider returns policy A,
    /// refill, provider returns policy B, refill, assert behaviour changed.
    ///
    /// Drives the REAL ``NTSStationController/refillPool()`` — not the pure
    /// planner — because a provider that is read once at pipeline start
    /// would still pass a planner-level test while freezing the dial for the
    /// whole broadcast.
    func testPolicyIsRereadAtEveryRefill_notSnapshottedAtStart() async throws {
        let harness = try NTSHarness()
        defer { harness.tearDown() }

        // Policy A: toggle OFF. Classification still runs, nothing is dropped.
        await harness.setPolicy(SelectionPolicy(excludeMixSets: false))
        try await harness.controller.refillPool()
        let poolA = await harness.controller.poolSnapshot()
        XCTAssertEqual(poolA.count, 3, "toggle off keeps every candidate")
        XCTAssertTrue(
            poolA.contains { $0.title == "Boiler Room 2019" },
            "the mix set must still be in the pool when the toggle is off"
        )

        // Policy B: toggle ON. Same station, same controller, no restart.
        await harness.setPolicy(SelectionPolicy(excludeMixSets: true))
        try await harness.controller.refillPool()
        let poolB = await harness.controller.poolSnapshot()
        XCTAssertEqual(poolB.count, 2, "the dial change must take effect at the NEXT refill, without a restart")
        XCTAssertFalse(
            poolB.contains { $0.title == "Boiler Room 2019" },
            "toggle on must remove the classified candidate at selection time"
        )
    }

    /// NTS supplies no duration (the key is present but null on all 21 rows
    /// of the tracklist fixture), so the title arm carries the entire load.
    func testNTSRecordsTitleArmOnly_andShadowLogsWhenToggleIsOff() async throws {
        let harness = try NTSHarness()
        defer { harness.tearDown() }

        await harness.setPolicy(SelectionPolicy(excludeMixSets: false))
        try await harness.controller.refillPool()

        let rows = try await harness.history.exclusions(stationID: harness.config.id, limit: 50)
        XCTAssertEqual(rows.count, 1, "only candidates that CLASSIFY are logged, not the whole pool")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.title, "Boiler Room 2019")
        XCTAssertEqual(row.arm, SelectionArm.title, "NTS has no duration at selection time — title arm only")
        XCTAssertNil(row.durationSeconds)
        XCTAssertNil(row.durationSource)
        XCTAssertEqual(row.sourceKind, "nts")
        XCTAssertFalse(row.enforced, "toggle off shadow-logs")
        XCTAssertFalse(row.everEnforced)

        // Same pool, toggle now on: the row flips to enforced.
        await harness.setPolicy(SelectionPolicy(excludeMixSets: true))
        try await harness.controller.refillPool()
        let after = try await harness.history.exclusions(stationID: harness.config.id, limit: 50)
        let flipped = try XCTUnwrap(after.first { $0.arm == SelectionArm.title })
        XCTAssertTrue(flipped.enforced)
        XCTAssertTrue(flipped.everEnforced)
    }

    /// An unchanged policy must not trigger a spurious mid-pool re-filter —
    /// that double-counts `hit_count` on every sighting and makes the audit
    /// log lie about how often the rule fired.
    func testUnchangedPolicyDoesNotDoubleCountHits() async throws {
        let harness = try NTSHarness()
        defer { harness.tearDown() }

        await harness.setPolicy(SelectionPolicy(excludeMixSets: false))
        try await harness.controller.refillPool()
        let firstRows = try await harness.history.exclusions(stationID: harness.config.id, limit: 50)
        let firstHits = try XCTUnwrap(firstRows.first?.hitCount)

        // Ask for a candidate: the controller checks the live policy. It has
        // not changed, so no re-filter and no second sighting.
        _ = await harness.controller.reapplyPolicyIfChangedForTesting()
        let secondRows = try await harness.history.exclusions(stationID: harness.config.id, limit: 50)
        XCTAssertEqual(secondRows.first?.hitCount, firstHits, "an unchanged policy must not re-log the same candidate")
    }

    // MARK: - Playlist source

    private func libraryTrack(_ title: String, _ artist: String, duration: TimeInterval) -> Track {
        Track(
            url: URL(fileURLWithPath: "/tmp/\(title).m4a"),
            title: title,
            artist: artist,
            album: "",
            duration: duration,
            genre: nil
        )
    }

    func testPlaylistToggleOff_playsTheLongRecordAndShadowLogsIt() async throws {
        let box = ExclusionBox()
        let source = PlaylistSource(
            tracks: [
                libraryTrack("Twenty Five Minutes Of Ambient", "Stars of the Lid", duration: 1500),
                libraryTrack("Short One", "Autechre", duration: 200),
            ],
            shuffle: false,
            selectionPolicy: { SelectionPolicy(excludeMixSets: false) },
            recordExclusions: { rows in await box.append(rows) }
        )

        let item = try await source.nextURL()
        XCTAssertEqual(item?.title, "Twenty Five Minutes Of Ambient", "toggle off must not drop the owner's own record")

        let rows = await box.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].arm, SelectionArm.duration)
        XCTAssertEqual(rows[0].durationSeconds, 1500)
        XCTAssertEqual(rows[0].durationSource, "library", "AVFoundation gives the EXACT length here")
        XCTAssertEqual(rows[0].sourceKind, "playlist")
        XCTAssertFalse(rows[0].enforced)
    }

    func testPlaylistToggleOn_skipsTheClassifiedTrackAtSelectionTime() async throws {
        let box = ExclusionBox()
        let source = PlaylistSource(
            tracks: [
                libraryTrack("Twenty Five Minutes Of Ambient", "Stars of the Lid", duration: 1500),
                libraryTrack("Short One", "Autechre", duration: 200),
            ],
            shuffle: false,
            selectionPolicy: { SelectionPolicy(excludeMixSets: true) },
            recordExclusions: { rows in await box.append(rows) }
        )

        let item = try await source.nextURL()
        XCTAssertEqual(item?.title, "Short One", "the classified track must be skipped, not returned then filtered")

        let rows = await box.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].enforced)
    }

    func testPlaylistStandsDownRatherThanReturningNil() async throws {
        // nextURL() returning nil kills the pipeline. An all-classified
        // queue must fall back, not go silent.
        let box = ExclusionBox()
        let source = PlaylistSource(
            tracks: [
                libraryTrack("Long A", "X", duration: 1500),
                libraryTrack("Long B", "Y", duration: 1600),
            ],
            shuffle: false,
            selectionPolicy: { SelectionPolicy(excludeMixSets: true) },
            recordExclusions: { rows in await box.append(rows) }
        )

        let item = try await source.nextURL()
        XCTAssertNotNil(item, "an all-classified queue must stand down, not return nil and kill the pipeline")

        let rows = await box.rows
        XCTAssertTrue(rows.contains { $0.arm == SelectionArm.starvationGuard })
        XCTAssertTrue(rows.allSatisfy { !$0.enforced }, "standing down drops nothing")
    }

    /// The dial does not apply to a playlist: everything is owned, so there
    /// is nothing to choose between. A source that ran `orderByNewness`
    /// anyway would report a shortfall on every single call.
    func testPlaylistNeverReportsAShortfall() async throws {
        let box = ExclusionBox()
        let source = PlaylistSource(
            tracks: [
                libraryTrack("One", "X", duration: 200),
                libraryTrack("Two", "Y", duration: 210),
            ],
            shuffle: false,
            selectionPolicy: { SelectionPolicy(newMusicShare: 1.0, excludeMixSets: true) },
            recordExclusions: { rows in await box.append(rows) }
        )
        _ = try await source.nextURL()
        _ = try await source.nextURL()

        let rows = await box.rows
        XCTAssertFalse(
            rows.contains { $0.arm == SelectionArm.shortfall },
            "the dial must not run on an all-owned queue"
        )
    }

    // MARK: - Bandcamp: the duration the decoder used to throw away

    func testBandcampDecodesFeaturedTrackDuration() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "bandcamp-discover-techno", withExtension: "json", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "bandcamp-discover-techno", withExtension: "json")
        )
        let (releases, _) = BandcampClient.parseDiscoverPage(data: try Data(contentsOf: url))
        XCTAssertEqual(releases.count, 48)
        XCTAssertTrue(
            releases.allSatisfy { $0.featuredTrackDurationSeconds != nil },
            "featured_track.duration is present on 48/48 fixture items and must no longer be discarded"
        )
        let longOnes = releases.filter { ($0.featuredTrackDurationSeconds ?? 0) >= 1200 }
        XCTAssertEqual(longOnes.count, 4, "4 fixture items exceed 1200s on the featured track alone")
    }

    /// The caveat, pinned so nobody papers over it later: every fixture item
    /// is an ALBUM, the candidate title is the RELEASE title, and what plays
    /// is the release — so this arm drops a whole release on the strength of
    /// ONE track's length. `duration_source` must say exactly that.
    func testBandcampDurationSourceNamesTheFeaturedTrack() async throws {
        let release = BandcampRelease(
            artist: "Some Label",
            title: "Compilation Vol 3",
            releaseURL: URL(string: "https://x.bandcamp.com/album/comp-3")!,
            releaseDate: nil,
            featuredTrackDurationSeconds: 1800
        )
        let harness = try BandcampHarness()
        defer { harness.tearDown() }
        await harness.controller.indexDurationsForTesting([release])

        let subject = await harness.controller.selectionSubjectForTesting(
            SourceCandidate(artist: release.artist, title: release.title)
        )
        XCTAssertEqual(subject.durationSeconds, 1800)
        XCTAssertEqual(
            subject.durationSource, "listing-featured-track",
            "NOT 'listing' — the measurement is one track, the removal is the whole release"
        )
    }

    // MARK: - Last.fm: no duration field exists anywhere in the API surface

    func testLastFMSuppliesNoDurationSoTheTitleArmCarriesTheLoad() async throws {
        let harness = try LastFMHarness()
        defer { harness.tearDown() }
        let subject = await harness.controller.selectionSubjectForTesting(
            SourceCandidate(artist: "Someone", title: "Boiler Room 2019")
        )
        XCTAssertNil(subject.durationSeconds, "Last.fm has no duration field, before or after the fetch")
        XCTAssertNil(subject.durationSource)

        let verdict = MixSetRule.classify(title: subject.title, durationSeconds: subject.durationSeconds)
        guard case .title = try XCTUnwrap(verdict) else {
            return XCTFail("a nil duration must yield a title-arm-only outcome")
        }
    }

    // MARK: - Ownership index

    func testOwnedArtistKeysUsesTheOneArtistKeyRule() async {
        let profile = TasteProfile()
        await profile.ingestLibrary([
            libraryTrack("a", "Aphex Twin", duration: 1),
            libraryTrack("b", "  Boards of Canada  ", duration: 1),
        ])
        let keys = await profile.ownedArtistKeys()
        XCTAssertEqual(keys, ["aphex twin", "boards of canada"])

        // The existing accessor must be left exactly as it was: it feeds
        // `score`'s libraryMatch term (25% of the blend stage 8 sorts on)
        // and FacetedPipeline's "exclude my library" facet.
        let lowercased = await profile.libraryContainsArtist("aphex twin")
        let exact = await profile.libraryContainsArtist("Aphex Twin")
        XCTAssertFalse(lowercased, "libraryContainsArtist must NOT become case-insensitive in this slice")
        XCTAssertTrue(exact)
    }
}

// MARK: - Helpers

/// Collects the exclusion rows a cross-platform source hands back, so the
/// tests can assert on them without a ``HistoryStore``.
private actor ExclusionBox {
    var rows: [SelectionExclusionRecord] = []
    func append(_ new: [SelectionExclusionRecord]) { rows.append(contentsOf: new) }
}

/// Answers NTS API requests from memory. The suite has no `URLProtocol`
/// stub yet and the tests must not touch the network.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Data] = [:]

    static func set(_ routes: [String: Data]) {
        lock.lock(); defer { lock.unlock() }
        self.routes = routes
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]
    }

    private static func body(forPath path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return routes[path]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let key = url.path + (url.query.map { "?\($0)" } ?? "")
        let data = Self.body(forPath: key) ?? Data(#"{"results":[]}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A real ``NTSStationController`` wired to stubbed HTTP and a temp
/// ``HistoryStore``, with a mutable selection-policy provider.
private final class NTSHarness {
    let controller: NTSStationController
    let history: HistoryStore
    let config: NTSStationConfig
    private let dbURL: URL
    private let cacheRoot: URL
    private let policy = PolicyBox()

    init() throws {
        StubURLProtocol.set([
            "/api/v2/shows?offset=0": Data(#"""
                {"results":[{"show_alias":"test-show","name":"Test Show","updated":null,
                             "genres":[{"id":"g","value":"Ambient"}]}]}
                """#.utf8),
            "/api/v2/shows?offset=12": Data(#"{"results":[]}"#.utf8),
            "/api/v2/shows/test-show/episodes?limit=1": Data(#"{"results":[{"episode_alias":"ep1"}]}"#.utf8),
            "/api/v2/shows/test-show/episodes/ep1/tracklist": Data(#"""
                {"results":[
                  {"artist":"Aaa","title":"Boiler Room 2019","duration":null},
                  {"artist":"Bbb","title":"Ordinary Track","duration":null},
                  {"artist":"Ccc","title":"Another Track","duration":null}
                ]}
                """#.utf8),
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-binding-\(UUID()).db")
        history = try HistoryStore(databaseURL: dbURL)
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-binding-cache-\(UUID())")
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: cacheRoot
        )
        config = NTSStationConfig(
            name: "Test",
            query: FacetedQuery(genreTags: ["ambient"]),
            shufflePool: false
        )
        let box = policy
        controller = NTSStationController(
            config: config,
            nts: NTSClient(session: session),
            musicBrainz: MusicBrainzClient(userAgent: "Ratbat/test"),
            lastFM: nil,
            history: history,
            resolver: resolver,
            tasteProfile: TasteProfile(),
            selectionPolicy: { await box.value }
        )
    }

    func setPolicy(_ new: SelectionPolicy) async { await policy.set(new) }

    func tearDown() {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}

private actor PolicyBox {
    var value: SelectionPolicy = .default
    func set(_ new: SelectionPolicy) { value = new }
}

/// Construction-only harness: these tests call the subject mapper, never
/// the network or the resolver subprocess.
private final class BandcampHarness {
    let controller: BandcampStationController
    private let dbURL: URL
    private let cacheRoot: URL

    init() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-bc-\(UUID()).db")
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-bc-cache-\(UUID())")
        let history = try HistoryStore(databaseURL: dbURL)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: cacheRoot
        )
        controller = BandcampStationController(
            config: BandcampStationConfig(name: "T", query: FacetedQuery(genreTags: ["techno"])),
            client: BandcampClient(userAgent: "Ratbat/test"),
            musicBrainz: MusicBrainzClient(userAgent: "Ratbat/test"),
            history: history,
            resolver: resolver,
            tasteProfile: TasteProfile()
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}

private final class LastFMHarness {
    let controller: LastFMStationController
    private let dbURL: URL
    private let cacheRoot: URL

    init() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-lfm-\(UUID()).db")
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-lfm-cache-\(UUID())")
        let history = try HistoryStore(databaseURL: dbURL)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: cacheRoot
        )
        controller = LastFMStationController(
            config: LastFMStationConfig(name: "T", query: FacetedQuery(genreTags: ["techno"])),
            client: LastFMClient(apiKey: "test"),
            musicBrainz: MusicBrainzClient(userAgent: "Ratbat/test"),
            history: history,
            resolver: resolver,
            tasteProfile: TasteProfile()
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}
#endif
