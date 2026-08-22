#if os(macOS)
import XCTest
@testable import RatbatCore

/// Boost-as-steering at the controller: a boosted artist arrives as a
/// seed OVERRIDE and leads the similar-artist expansion at the very next
/// refill, and ``LastFMStationController/requestReseed()`` makes that
/// refill happen mid-pool instead of waiting for the pool to drain.
///
/// No network: the shared ``StubURLProtocol`` (SelectionBindingTests)
/// answers every Last.fm request from in-memory fixtures and records the
/// order requests arrive in — which is how the tests can see WHERE in
/// the expansion queue an override landed, not just that it landed.
final class LastFMStationControllerTests: XCTestCase {

    // MARK: - Seed merge (pure)

    func testMergeSeedArtists_overridesLeadAffinityFollows() {
        let merged = LastFMStationController.mergeSeedArtists(
            overrides: ["Boosted"],
            affinity: ["Loved", "Played"]
        )
        XCTAssertEqual(merged, ["Boosted", "Loved", "Played"],
                       "the boosted artist must be at the FRONT of the expansion queue")
    }

    func testMergeSeedArtists_dedupsCaseInsensitivelyKeepingTheOverrideSpelling() {
        let merged = LastFMStationController.mergeSeedArtists(
            overrides: ["portishead"],
            affinity: ["Portishead", "Coil"]
        )
        XCTAssertEqual(merged, ["portishead", "Coil"],
                       "an artist both boosted and loved is one seed, in override position")
    }

    func testMergeSeedArtists_capsTheQueueAndDropsBlanks() {
        let merged = LastFMStationController.mergeSeedArtists(
            overrides: ["A", " ", "B"],
            affinity: ["C", "D", "E"]
        )
        XCTAssertEqual(merged, ["A", "B", "C", "D"],
                       "hard-bounded so a refill can't blow the Last.fm rate budget")
    }

    // MARK: - Steering through a real refill

    /// The headline: a refill with no override plays the tag pool; after
    /// a boost lands (override set + ``requestReseed()``), the NEXT
    /// nextTrack-time reseed check rebuilds the pool through the boosted
    /// artist's neighbours — mid-pool, without the pool having drained.
    func testSeedOverrideSteersTheNextRefill_andRequestReseedForcesItMidPool() async throws {
        let harness = try SteeringHarness()
        defer { harness.tearDown() }

        // Refill 1: no override. Pool is the tag fetch alone; nobody
        // asked Last.fm for similar artists.
        try await harness.controller.refillPool()
        let before = await harness.controller.poolSnapshot()
        XCTAssertEqual(before.map(\.title), ["Tag Song"])
        XCTAssertFalse(
            StubURLProtocol.requestedKeys().contains { $0.contains("artist.getsimilar") },
            "no boost, no expansion"
        )

        // The boost: override lands (broadcaster side) and the source
        // marks the pool stale (requestReseed). The unconsumed pool must
        // stay as it is until the encode loop asks for its next track —
        // steering must never yank the needle.
        await harness.seeds.set(["OverrideX"])
        await harness.controller.requestReseed()
        let midTrack = await harness.controller.poolSnapshot()
        XCTAssertEqual(midTrack.map(\.title), ["Tag Song"], "reseed is deferred, not immediate")

        // The next-track reseed check: rebuilds through OverrideX's
        // neighbours. The neighbour outranks the tag track on listeners,
        // so the `.hits` tier keeps it — the override visibly changed
        // what the station will play next.
        try await harness.controller.refillIfReseedPending()
        let after = await harness.controller.poolSnapshot()
        XCTAssertEqual(after.map(\.title), ["Neighbour Song"],
                       "the boosted artist's neighbourhood leads the rebuilt pool")
        XCTAssertTrue(
            StubURLProtocol.requestedKeys().contains {
                $0.contains("method=artist.getsimilar") && $0.contains("artist=OverrideX")
            },
            "the override was expanded via the similar-artist API"
        )

        // The flag is consumed: a further check without a new boost must
        // not refill again (no new tag-fetch traffic).
        let requestsAfterReseed = StubURLProtocol.requestedKeys().count
        try await harness.controller.refillIfReseedPending()
        XCTAssertEqual(StubURLProtocol.requestedKeys().count, requestsAfterReseed,
                       "requestReseed is one refill, not a standing order")
    }

    /// Overrides go to the FRONT of the expansion queue: with both a
    /// boost override and a ♥-earned affinity seed in play, Last.fm is
    /// asked about the override first.
    func testOverridesAreExpandedBeforeAffinitySeeds() async throws {
        let harness = try SteeringHarness()
        defer { harness.tearDown() }

        // A ♥ on AffinityA gives the station one affinity seed.
        let row = try await harness.history.record(
            station: harness.config.id, artist: "AffinityA", title: "Loved One"
        )
        try await harness.history.markSaved(id: row, cachedPath: "/tmp/loved.m4a")

        await harness.seeds.set(["OverrideX"])
        try await harness.controller.refillPool()

        let keys = StubURLProtocol.requestedKeys()
        let overrideIdx = keys.firstIndex {
            $0.contains("method=artist.getsimilar") && $0.contains("artist=OverrideX")
        }
        let affinityIdx = keys.firstIndex {
            $0.contains("method=artist.getsimilar") && $0.contains("artist=AffinityA")
        }
        let o = try XCTUnwrap(overrideIdx, "override was never expanded")
        let a = try XCTUnwrap(affinityIdx, "affinity seed was never expanded")
        XCTAssertLessThan(o, a, "boost override must lead the expansion queue")
    }
}

// MARK: - Harness

/// Mutable seed-override provider, standing in for the broadcaster's
/// consume-once `seedOverrideProvider`.
private actor SeedOverrideBox {
    var value: [String] = []
    func set(_ new: [String]) { value = new }
}

/// A real ``LastFMStationController`` on stubbed HTTP and a temp
/// ``HistoryStore``. Fixture geography: the `techno` tag yields one
/// low-listener track; `OverrideX`'s only neighbour `NeighbourN` has a
/// high-listener track, so under the `.hits` tier the neighbour wins the
/// pool if — and only if — the override was expanded.
private final class SteeringHarness {
    let controller: LastFMStationController
    let history: HistoryStore
    let config: LastFMStationConfig
    let seeds = SeedOverrideBox()
    private let dbURL: URL
    private let cacheRoot: URL

    init() throws {
        StubURLProtocol.set([
            "/2.0?method=tag.gettoptracks&tag=techno&limit=100&page=1&api_key=test&format=json": Data(#"""
                {"tracks":{"track":[
                  {"name":"Tag Song","artist":{"name":"TagArtist"},"listeners":"10","playcount":"5"}
                ]}}
                """#.utf8),
            "/2.0?method=tag.gettoptracks&tag=techno&limit=100&page=2&api_key=test&format=json": Data(#"""
                {"tracks":{"track":[]}}
                """#.utf8),
            "/2.0?method=artist.getsimilar&artist=OverrideX&autocorrect=1&limit=6&api_key=test&format=json": Data(#"""
                {"similarartists":{"artist":[{"name":"NeighbourN"}]}}
                """#.utf8),
            "/2.0?method=artist.gettoptracks&artist=NeighbourN&autocorrect=1&limit=2&api_key=test&format=json": Data(#"""
                {"toptracks":{"track":[
                  {"name":"Neighbour Song","artist":{"name":"NeighbourN"},"listeners":"9000","playcount":"9"}
                ]}}
                """#.utf8),
            // Stage-5 precision verification asks for each candidate
            // artist's top tags and drops anyone whose top-5 miss the
            // query tags — an UNSTUBBED artist decodes to an empty tag
            // list and gets dropped, so both playable artists must
            // answer with the query tag.
            "/2.0?method=artist.gettoptags&artist=TagArtist&autocorrect=1&api_key=test&format=json": Data(#"""
                {"toptags":{"tag":[{"name":"Techno","count":100}]}}
                """#.utf8),
            "/2.0?method=artist.gettoptags&artist=NeighbourN&autocorrect=1&api_key=test&format=json": Data(#"""
                {"toptags":{"tag":[{"name":"Techno","count":100}]}}
                """#.utf8),
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm-steering-\(UUID()).db")
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm-steering-cache-\(UUID())")
        history = try HistoryStore(databaseURL: dbURL)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: cacheRoot
        )
        // `.hits` keeps only the top listener slice, which is what lets
        // the pool CONTENTS prove whether the expansion ran.
        config = LastFMStationConfig(
            name: "Steer",
            query: FacetedQuery(genreTags: ["techno"], popularity: .hits)
        )
        let box = seeds
        controller = LastFMStationController(
            config: config,
            client: LastFMClient(apiKey: "test", session: session),
            musicBrainz: MusicBrainzClient(userAgent: "Ratbat/test"),
            history: history,
            resolver: resolver,
            tasteProfile: TasteProfile(),
            seedOverride: { await box.value }
        )
    }

    func tearDown() {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}
#endif
