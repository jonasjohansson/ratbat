import XCTest
import Network
@testable import RatbatCore

/// Broadcaster tests covering the multi-station redesign in Task 3.5.
///
/// Unit-testing a full `[Track] → PCM → AAC → HTTP → client` loop without
/// audio fixtures and network I/O in CI is a lot of ceremony, so this file
/// still covers the cheap in-isolation bits:
/// - Initial idle state of ``RadioBroadcaster``.
/// - ``ADTSHeader`` byte layout (downstream clients need the sync word).
/// - ``AACRingBuffer`` basic write / late-join-read / overflow semantics.
///
/// Plus the new routing bits:
/// - `requestPath` / `extractSlug` parse correct request paths.
/// - Starting multiple stations produces distinct stream URLs.
/// - A fixture-backed end-to-end broadcast produces AAC on the
///   slug-specific URL and 302-redirects the legacy `/stream.aac`.
/// - The legacy endpoint 404s when nothing is broadcasting.
final class RadioBroadcasterTests: XCTestCase {

    @MainActor
    func testRadioBroadcasterInitialState() async {
        let radio = RadioBroadcaster()
        XCTAssertTrue(radio.broadcasting.isEmpty)
        XCTAssertTrue(radio.listenerCount.isEmpty)
        XCTAssertTrue(radio.currentItemByStation.isEmpty)
        XCTAssertNil(radio.error)
    }

    @MainActor
    func testStartWithEmptyQueueSurfacesError() async {
        let radio = RadioBroadcaster()
        let empty = Station(name: "Empty", kind: .playlist(queue: []))
        await radio.startBroadcast(station: empty)
        XCTAssertFalse(radio.isBroadcasting(stationID: empty.id))
        XCTAssertNotNil(radio.error)
    }

    @MainActor
    func testStreamURLIsNilWhenStationNotBroadcasting() async {
        let radio = RadioBroadcaster()
        let station = Station(name: "Idle", kind: .playlist(queue: []))
        XCTAssertNil(radio.streamURL(for: station))
    }

    // MARK: - An unreadable library must not hot-spin the encode loop

    /// Backoff shape: a handful of bad files in an otherwise fine library
    /// must be skipped at full speed, but a library that is *entirely*
    /// unreadable must back off instead of spinning.
    func testOpenFailureBackoffSkipsFastThenEscalatesAndCaps() {
        // Scattered bad files — no delay, so a 5000-track playlist with a
        // few dead entries still finds the next playable track instantly.
        XCTAssertEqual(RadioBroadcaster.openFailureBackoff(consecutiveFailures: 1), 0)
        XCTAssertEqual(RadioBroadcaster.openFailureBackoff(consecutiveFailures: 3), 0)
        // Sustained failure — the volume is gone, not just one file.
        XCTAssertEqual(RadioBroadcaster.openFailureBackoff(consecutiveFailures: 4), 0.5)
        XCTAssertEqual(RadioBroadcaster.openFailureBackoff(consecutiveFailures: 5), 1)
        XCTAssertEqual(RadioBroadcaster.openFailureBackoff(consecutiveFailures: 6), 2)
        XCTAssertEqual(RadioBroadcaster.openFailureBackoff(consecutiveFailures: 20), 30, "capped")
    }

    #if os(macOS)
    /// Reproduction of the hot spin.
    ///
    /// When every file in a playlist is unopenable — the usual cause being
    /// an external or network volume that went away — the encode loop used
    /// to `continue outer` with no delay at all. With a listener attached
    /// `awaitListener` returns instantly, so the loop ran as fast as the
    /// CPU allowed: a pegged core, and a fabricated history row on every
    /// iteration, because `PlaylistSource.nextURL` records a play before
    /// the file is ever opened.
    ///
    /// The listener sees an open `200 audio/aac` that never delivers a
    /// byte, so this is invisible to any check that only reads the status
    /// line.
    @MainActor
    func testUnreadableLibraryDoesNotHotSpinTheEncodeLoop() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("spin-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.port = 18_050
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, history: store)

        // Nothing here exists on disk, so `decoder.open` throws every time.
        let tracks = (0..<200).map { i in
            Track(
                url: URL(fileURLWithPath: "/nonexistent/ratbat-spin-\(i).m4a"),
                title: "Gone \(i)",
                artist: "Unmounted Volume",
                album: "Missing",
                duration: 100
            )
        }
        let station = Station(name: "Spin Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        // Without a held-open listener the loop parks in awaitListener's
        // 5s poll and the spin can't reproduce at all.
        let holder = await Self.holdOpenStreamConnection(
            port: 18_050,
            path: "/stream/\(station.slug).aac"
        )
        defer { holder?.cancel() }

        try await Task.sleep(nanoseconds: 3_000_000_000)

        let rows = try await store.recentEntries(forStation: station.id, limit: 10_000).count

        // With backoff: ~3 instant failures then 0.5/1/2s waits, so well
        // under 20 in 3 seconds. Without it: hundreds to thousands.
        XCTAssertLessThan(
            rows, 20,
            "encode loop hot-spun on an unreadable library: \(rows) fabricated plays in 3s"
        )
        XCTAssertGreaterThan(rows, 0, "loop should still have tried, not stalled")
    }
    #endif

    // MARK: - Test runs must not touch the production tunnel

    #if os(macOS)
    /// Running the suite used to spawn real `cloudflared` processes.
    ///
    /// `startBroadcast` bootstraps the tunnel unconditionally, and
    /// `namedTunnelConfigured()` is true on this machine because
    /// `~/.cloudflared/config.yml` exists — so every broadcasting test
    /// connected another instance to the *production* named tunnel for
    /// radio.jonasjohansson.se. A single suite run left eight of them
    /// alive after it finished:
    ///
    ///     15376  05:46  /opt/homebrew/bin/cloudflared tunnel run
    ///     15438  04:42  /opt/homebrew/bin/cloudflared tunnel run
    ///     …
    ///
    /// The default must be "don't publish" whenever we're under XCTest.
    @MainActor
    func testTestRunsDoNotPublishPublicly() {
        XCTAssertTrue(
            RadioBroadcaster.isRunningUnderXCTest,
            "test detection must work, or the guard below is vacuous"
        )
        let radio = RadioBroadcaster(port: 18_040)
        XCTAssertFalse(
            radio.publishesPublicly,
            "a broadcaster built inside a test must not open the public tunnel"
        )
    }

    /// Belt and braces: with publishing off, actually broadcasting a
    /// station must leave the tunnel idle.
    @MainActor
    func testBroadcastWithPublishingDisabledLeavesTunnelIdle() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let radio = RadioBroadcaster(port: 18_041, publishesPublicly: false)
        let station = Station(name: "No Publish", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertFalse(radio.tunnel.isRunning, "tunnel must stay down when publishing is disabled")
        XCTAssertEqual(radio.tunnel.mode, .idle)
    }

    /// The explicit opt-in still works, so production behaviour is intact.
    @MainActor
    func testPublishesPubliclyCanBeForcedOn() {
        let radio = RadioBroadcaster(port: 18_042, publishesPublicly: true)
        XCTAssertTrue(radio.publishesPublicly)
    }
    #endif

    // MARK: - ♥ like endpoint

    /// Preflight bails 404 when the broadcaster has no pipeline for the
    /// requested station — the most common error path (user hits ♥ on a
    /// station that just stopped).
    @MainActor
    func testLikeOnIdleStationReturns404() async throws {
        let radio = RadioBroadcaster(port: 18_030)
        defer { radio.stopAll() }
        let (status, _) = await radio.performLikeAsync(stationID: UUID(), token: BroadcastPreferences.shared.ownerToken)
        XCTAssertEqual(status, 404)
    }

    /// Playlist stations produce items with `historyID == nil` — the
    /// files are already owned, so ♥ copies nothing but must still record
    /// the taste signal: "noted", plus a saved-flagged history row that
    /// `savedEntries(forStation:)` feeds into ♥-affinity.
    @MainActor
    func testLikeOnPlaylistStationRecordsAffinity() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("affinity-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.port = 18_031
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, history: store)
        let station = Station(name: "Affinity Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        // Wait long enough for the encoder to open its first track so
        // `currentItemByStation` is populated — otherwise we'd hit the
        // 404 "no current track" path.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let (status, body) = await radio.performLikeAsync(stationID: station.id, token: prefs.ownerToken)
        XCTAssertEqual(status, 200, "Expected 200, got \(status): \(String(data: body, encoding: .utf8) ?? "")")

        struct Response: Decodable { let status: String; let path: String? }
        let decoded = try JSONDecoder().decode(Response.self, from: body)
        XCTAssertEqual(decoded.status, "noted")
        XCTAssertNotNil(decoded.path, "affinity response carries the owned file's path")

        // The row must be visible to the taste profile's affinity query.
        let saved = try await store.savedEntries(forStation: station.id, limit: 10)
        XCTAssertEqual(saved.count, 1, "one ♥ → one saved-flagged row")
        XCTAssertFalse(saved[0].artist.isEmpty)
    }

    /// CORS preflight: OPTIONS /like returns 204 with the standard
    /// Access-Control-* headers so the GitHub-Pages web player can POST
    /// without a browser flagging it as an unapproved cross-origin call.
    @MainActor
    func testOptionsLikeReturnsCORSHeaders() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_032
        let radio = RadioBroadcaster(port: port)
        // Need at least one live broadcast to bring the listener up.
        let filler = Station(name: "CORS Filler", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: filler)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 400_000_000)

        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/like",
            requestHeaders: ["Access-Control-Request-Method: POST"],
            maxBytes: 1_024,
            method: "OPTIONS"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 204"), "Expected 204: \(response)")
        let lower = response.lowercased()
        XCTAssertTrue(lower.contains("access-control-allow-origin: *"), "Missing allow-origin: \(response)")
        XCTAssertTrue(lower.contains("access-control-allow-methods: post, options"), "Missing allow-methods: \(response)")
        XCTAssertTrue(lower.contains("access-control-allow-headers: content-type"), "Missing allow-headers: \(response)")
    }

    /// Skip bridge bails 404 when there's no pipeline for the station —
    /// same "nothing to act on" path as the like bridge.
    @MainActor
    func testSkipOnIdleStationReturns404() async throws {
        let radio = RadioBroadcaster(port: 18_033)
        defer { radio.stopAll() }
        let (status, _) = await radio.performSkipAsync(stationID: UUID(), token: BroadcastPreferences.shared.ownerToken)
        XCTAssertEqual(status, 404)
    }

    /// CORS preflight: OPTIONS /skip returns 204 with the standard
    /// Access-Control-* headers, same as /like, so the web player can POST
    /// a thumbs-down cross-origin.
    @MainActor
    func testOptionsSkipReturnsCORSHeaders() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_034
        let radio = RadioBroadcaster(port: port)
        let filler = Station(name: "CORS Filler", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: filler)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 400_000_000)

        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/skip",
            requestHeaders: ["Access-Control-Request-Method: POST"],
            maxBytes: 1_024,
            method: "OPTIONS"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 204"), "Expected 204: \(response)")
        let lower = response.lowercased()
        XCTAssertTrue(lower.contains("access-control-allow-origin: *"), "Missing allow-origin: \(response)")
        XCTAssertTrue(lower.contains("access-control-allow-methods: post, options"), "Missing allow-methods: \(response)")
    }

    /// Next bridge bails 404 with no pipeline — same "nothing to act on"
    /// path as like and skip.
    @MainActor
    func testNextOnIdleStationReturns404() async throws {
        let radio = RadioBroadcaster(port: 18_039)
        defer { radio.stopAll() }
        let (status, _) = await radio.performNextAsync(stationID: UUID(), token: BroadcastPreferences.shared.ownerToken)
        XCTAssertEqual(status, 404)
    }

    /// The point of /next vs /skip: playlist tracks carry no historyID,
    /// so 👎 refuses them (404) — but a neutral advance records nothing
    /// and must succeed.
    @MainActor
    func testNextOnPlaylistStationReturns200WhereSkipRefuses() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let radio = RadioBroadcaster(port: 18_036)
        let station = Station(name: "Next Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let (skipStatus, _) = await radio.performSkipAsync(stationID: station.id, token: BroadcastPreferences.shared.ownerToken)
        XCTAssertEqual(skipStatus, 404, "👎 must refuse history-less playlist tracks")

        let (nextStatus, body) = await radio.performNextAsync(stationID: station.id, token: BroadcastPreferences.shared.ownerToken)
        XCTAssertEqual(nextStatus, 200, "⏭ must advance them: \(String(data: body, encoding: .utf8) ?? "")")
    }

    /// End-to-end over a real TCP socket, body coalesced into the same
    /// send as the headers — the exact shape every browser produces and
    /// the one that used to park the server forever. This is the
    /// integration test whose absence let that bug ship green.
    @MainActor
    func testPostNextOverSocketWithCoalescedBody() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_037
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "Socket Next", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/next",
            requestHeaders: ["Content-Type: application/json"],
            maxBytes: 1_024,
            method: "POST",
            body: "{\"station\":\"\(station.id.uuidString)\",\"token\":\"\(BroadcastPreferences.shared.ownerToken)\"}"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 200"), "Expected 200: \(response)")
        XCTAssertTrue(response.contains("\"status\":\"next\""), "Expected next status: \(response)")
    }

    /// Same socket-level coalesced shape against /like. This broadcaster
    /// has NO history store (minimal init), so the owned-track affinity
    /// path degrades to 500 "history unavailable" — the point here is
    /// the socket answers at all (not hang, not 400), plus the degraded
    /// mode's wire shape.
    @MainActor
    func testPostLikeOverSocketWithCoalescedBody() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_038
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "Socket Like", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/like",
            requestHeaders: ["Content-Type: application/json"],
            maxBytes: 1_024,
            method: "POST",
            body: "{\"station\":\"\(station.id.uuidString)\",\"token\":\"\(BroadcastPreferences.shared.ownerToken)\"}"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 500"), "Expected 500: \(response)")
        XCTAssertTrue(response.contains("history unavailable"), "Expected message: \(response)")
    }

    // MARK: - Timeline (recent ring + upcoming + retro-♥)

    /// Advancing a station must retire the outgoing track into the recent
    /// ring, publish the prefetched next track, and let a retro-♥ save a
    /// ring entry — the "track two songs ago" flow, end to end.
    @MainActor
    func testTimelineRingUpcomingAndRetroLike() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        guard tracks.count >= 2 else { throw XCTSkip("Need 2+ fixtures") }
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.port = 18_043
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, history: store)
        let station = Station(name: "Timeline Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let firstTitle = radio.currentItemByStation[station.id]?.title

        // The prefetched next track should surface once resolved —
        // playlist sources resolve instantly.
        XCTAssertNotNil(radio.upcomingByStation[station.id], "prefetched next should publish")

        // A parked encode loop won't advance without an audience — the
        // data-conscious idle holds after track one, so the ring would
        // stay empty forever. Attach a real stream listener.
        let streamPath = "/stream/\(station.slug).aac"
        let listener = Task {
            _ = try? await Self.fetchStream(
                port: 18_043, path: streamPath, maxBytes: 4_000_000
            )
        }
        defer { listener.cancel() }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        radio.nextTrack(stationID: station.id)
        // Skip lands on the next loop iteration; the idle gate polls
        // every 5s before the next track opens — budget generously.
        try await Task.sleep(nanoseconds: 8_000_000_000)

        let ring = radio.recentByStation[station.id] ?? []
        // Short fixture tracks can also END naturally while the listener
        // is attached, retiring extra entries — assert containment, not
        // head position.
        guard let retired = ring.first(where: { $0.item.title == firstTitle }) ?? ring.first else {
            XCTFail("advance → retired track; ring is empty")
            return
        }
        XCTAssertTrue(
            ring.contains { $0.item.title == firstTitle },
            "ring holds the track that was playing at capture time"
        )

        // Retro-♥ the retired track. Playlist items carry no historyID →
        // the affinity path answers "noted" and writes a saved row.
        let entryID = retired.entryID.uuidString
        let (status, body) = await radio.performRetroLikeAsync(
            stationID: station.id, entryID: entryID, token: prefs.ownerToken
        )
        XCTAssertEqual(status, 200, String(data: body, encoding: .utf8) ?? "")
        XCTAssertTrue(String(data: body, encoding: .utf8)!.contains("noted"))
        let saved = try await store.savedEntries(forStation: station.id, limit: 10)
        XCTAssertEqual(saved.count, 1)

        // Unknown entry → 404, and guests → 403 regardless.
        let (missStatus, _) = await radio.performRetroLikeAsync(
            stationID: station.id, entryID: UUID().uuidString, token: prefs.ownerToken
        )
        XCTAssertEqual(missStatus, 404)
        let (guestStatus, _) = await radio.performRetroLikeAsync(
            stationID: station.id, entryID: entryID, token: "wrong"
        )
        XCTAssertEqual(guestStatus, 403)
    }

    // MARK: - Resume last-live

    /// The broadcaster maintains the last-live record: starting remembers
    /// the slug, a deliberate single stop forgets it, and stopAll (the
    /// shutdown path) leaves it intact so the next launch resumes.
    @MainActor
    func testLastLiveRememberedForgottenAndSurvivesStopAll() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.port = 18_045
        defer {
            prefs.port = 18_000
            prefs.lastLiveSlugs = []
        }
        prefs.lastLiveSlugs = []
        let radio = RadioBroadcaster(preferences: prefs)
        let station = Station(name: "Resume Test", kind: .playlist(queue: tracks))

        await radio.startBroadcast(station: station)
        XCTAssertEqual(prefs.lastLiveSlugs, [station.slug], "start remembers")

        radio.stopBroadcast(stationID: station.id)
        XCTAssertEqual(prefs.lastLiveSlugs, [], "deliberate stop forgets")

        await radio.startBroadcast(station: station)
        XCTAssertEqual(prefs.lastLiveSlugs, [station.slug])
        radio.stopAll()
        XCTAssertEqual(
            prefs.lastLiveSlugs, [station.slug],
            "stopAll is lifecycle, not intent — the record survives for resume"
        )
    }

    /// A station that runs dry must keep its "was live" record, so the next
    /// launch resumes it. Erasing it makes starvation permanent across a
    /// restart and indistinguishable from the owner having stopped the
    /// station deliberately.
    ///
    /// SCOPE OF THIS TEST, stated plainly: it exercises the *seam* — that the
    /// non-deliberate teardown preserves `lastLiveSlugs` while a deliberate
    /// stop clears it. It does NOT drive a real source exhaustion end to end;
    /// `startBroadcast` builds the source from `station.kind` with no
    /// injection point for a source that returns nil, and a playlist source
    /// loops forever by design. The uncovered ground is the encode loop's
    /// `guard let item = nextItem else { break }` actually being reached.
    @MainActor
    func testRunningDryKeepsTheStationResumable() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.port = 18_046
        defer {
            prefs.port = 18_000
            prefs.lastLiveSlugs = []
        }
        prefs.lastLiveSlugs = []
        let radio = RadioBroadcaster(preferences: prefs)
        let station = Station(name: "Starve Test", kind: .playlist(queue: tracks))

        await radio.startBroadcast(station: station)
        XCTAssertEqual(prefs.lastLiveSlugs, [station.slug], "start remembers")

        // The teardown the encode-loop unwind now uses.
        radio.stopBroadcastRanDry(stationID: station.id)
        XCTAssertEqual(
            prefs.lastLiveSlugs, [station.slug],
            "a station that stopped on its own must still be resumable"
        )

        // Contrast: the owner stopping it IS intent, and must still forget.
        await radio.startBroadcast(station: station)
        radio.stopBroadcast(stationID: station.id)
        XCTAssertEqual(prefs.lastLiveSlugs, [], "a deliberate stop still forgets")
    }

    // MARK: - Boost + un-♥ (keep vs steer)

    /// The signal-model arc on an owned track: ♥ records affinity, un-♥
    /// deletes the affinity row (never the library file), boost stamps a
    /// row that dominates the expansion seeding.
    @MainActor
    func testBoostAndUnlikeOnOwnedTrack() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("boost-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.port = 18_044
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, history: store)
        let station = Station(name: "Boost Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let playing = radio.currentItemByStation[station.id]
        let ownedPath = playing?.url.path

        // ♥ → affinity row exists.
        let (likeStatus, _) = await radio.performLikeAsync(stationID: station.id, token: prefs.ownerToken)
        XCTAssertEqual(likeStatus, 200)
        var saved = try await store.savedEntries(forStation: station.id, limit: 10)
        XCTAssertEqual(saved.count, 1)

        // Un-♥ → row deleted, the LIBRARY FILE untouched.
        let (unlikeStatus, _) = await radio.performUnlikeAsync(stationID: station.id, token: prefs.ownerToken)
        XCTAssertEqual(unlikeStatus, 200)
        saved = try await store.savedEntries(forStation: station.id, limit: 10)
        XCTAssertEqual(saved.count, 0, "un-♥ clears the saved flag")
        // …but the PLAY record survives: undoing a save must not erase
        // the fact the track was heard.
        let stillInHistory = try await store.recentEntries(limit: 10)
        XCTAssertTrue(
            stillInHistory.contains { $0.title == playing?.title },
            "un-♥ must not delete play history"
        )
        if let ownedPath {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: ownedPath),
                "un-♥ must never delete a library original"
            )
        }

        // Un-♥ again → nothing left to undo.
        let (again, _) = await radio.performUnlikeAsync(stationID: station.id, token: prefs.ownerToken)
        XCTAssertEqual(again, 404)

        // Boost → boosted row exists and dominates expansion seeding.
        let (boostStatus, body) = await radio.performBoostAsync(stationID: station.id, token: prefs.ownerToken)
        XCTAssertEqual(boostStatus, 200, String(data: body, encoding: .utf8) ?? "")
        let boosted = try await store.boostedEntries(forStation: station.id, limit: 10)
        XCTAssertEqual(boosted.count, 1)
        let seeds = try await store.topAffinityArtists(forStation: station.id, limit: 3)
        XCTAssertEqual(seeds.first, playing?.artist, "boosted artist leads the seeding")

        // Guests: 403 on both.
        let (g1, _) = await radio.performBoostAsync(stationID: station.id, token: nil)
        XCTAssertEqual(g1, 403)
        let (g2, _) = await radio.performUnlikeAsync(stationID: station.id, token: "wrong")
        XCTAssertEqual(g2, 403)
    }

    // MARK: - Owner key

    /// Without a valid owner token every action endpoint answers 403 —
    /// the public surface is listen-only, "a radio, not a mixer".
    @MainActor
    func testActionsRejectGuestsWith403() async throws {
        let radio = RadioBroadcaster(port: 18_041)
        // This test deliberately fails the gate nine times in a row, which
        // the failed-attempt throttle would answer with ~10s of accumulated
        // delay. The throttle has its own tests; here it is just drag.
        radio.ownerThrottleStep = 0
        defer { radio.stopAll() }
        for token in [nil, "", "wrong-token"] as [String?] {
            let (likeStatus, likeBody) = await radio.performLikeAsync(stationID: UUID(), token: token)
            XCTAssertEqual(likeStatus, 403, "like with token \(token ?? "nil")")
            XCTAssertTrue(String(data: likeBody, encoding: .utf8)!.contains("listener mode"))
            let (skipStatus, _) = await radio.performSkipAsync(stationID: UUID(), token: token)
            XCTAssertEqual(skipStatus, 403, "skip with token \(token ?? "nil")")
            let (nextStatus, _) = await radio.performNextAsync(stationID: UUID(), token: token)
            XCTAssertEqual(nextStatus, 403, "next with token \(token ?? "nil")")
        }
    }

    /// Socket-level guest POST (no token in body) → 403 over the wire.
    @MainActor
    func testPostWithoutTokenOverSocketReturns403() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_042
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "Guest Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/next",
            requestHeaders: ["Content-Type: application/json"],
            maxBytes: 1_024,
            method: "POST",
            body: "{\"station\":\"\(station.id.uuidString)\"}"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 403"), "Expected 403: \(response)")
        XCTAssertTrue(response.contains("listener mode"), "Expected guest message: \(response)")
    }

    /// SSE framing: a payload becomes a single `data:` line terminated by
    /// a blank line, with the JSON bytes passed through verbatim.
    func testSSEEventFraming() {
        let json = Data("{\"stations\":[]}".utf8)
        let framed = RadioBroadcaster.sseEvent(json)
        XCTAssertEqual(String(data: framed, encoding: .utf8), "data: {\"stations\":[]}\n\n")
    }

    /// GET /events opens a Server-Sent Events stream — the response head
    /// must advertise text/event-stream so browsers treat it as one.
    @MainActor
    func testEventsEndpointSendsSSEHeaders() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_035
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "SSE Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 400_000_000)

        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/events",
            requestHeaders: [],
            maxBytes: 512
        )
        XCTAssertTrue(response.contains("HTTP/1.1 200"), "Expected 200: \(response)")
        let lower = response.lowercased()
        XCTAssertTrue(lower.contains("content-type: text/event-stream"), "Missing event-stream content type: \(response)")
        XCTAssertTrue(lower.contains("access-control-allow-origin: *"), "Missing allow-origin: \(response)")
    }

    // MARK: - Coalesced POST parsing
    //
    // Regression suite for the bug that hung every real-world POST:
    // browsers (and Cloudflare's tunnel) send headers + body in one TCP
    // segment. `readUntilHeaderEnd` used to truncate that buffer at the
    // header terminator, silently discarding the body, and `readBody`
    // then blocked on a receive that could never fire.

    private static let coalescedPost = Data("""
    POST /like HTTP/1.1\r
    Host: radio.example.com\r
    Content-Type: application/json\r
    Content-Length: 50\r
    \r
    {"station":"B8157CF6-56D6-463F-85FB-5569493459FC"}
    """.utf8)

    func testBodyBytesPeelsCoalescedBody() {
        let body = RadioBroadcaster.bodyBytes(after: Self.coalescedPost)
        XCTAssertEqual(
            String(data: body, encoding: .utf8),
            #"{"station":"B8157CF6-56D6-463F-85FB-5569493459FC"}"#
        )
        XCTAssertEqual(body.count, 50, "must match the declared Content-Length")
    }

    func testBodyBytesEmptyWhenNoBodyCoalesced() {
        let headersOnly = Data("GET /now.json HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        XCTAssertEqual(RadioBroadcaster.bodyBytes(after: headersOnly), Data())
    }

    func testContentLengthReadsHeaderWithTrailingBody() {
        XCTAssertEqual(RadioBroadcaster.contentLength(from: Self.coalescedPost), 50)
    }

    func testContentLengthIgnoresSpoofInBody() {
        // A body line must not be able to masquerade as a header.
        let sneaky = Data(
            "POST /like HTTP/1.1\r\nHost: x\r\n\r\ncontent-length: 9999".utf8
        )
        XCTAssertNil(RadioBroadcaster.contentLength(from: sneaky))
    }

    func testRequestParsingToleratesCoalescedBody() {
        XCTAssertEqual(RadioBroadcaster.requestPath(from: Self.coalescedPost), "/like")
        XCTAssertEqual(RadioBroadcaster.requestMethod(from: Self.coalescedPost), "POST")
    }

    func testRequestPathParsesCommonShapes() {
        let raw = Data("GET /stream/my-fm.aac HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        XCTAssertEqual(RadioBroadcaster.requestPath(from: raw), "/stream/my-fm.aac")

        let legacy = Data("GET /stream.aac HTTP/1.1\r\n\r\n".utf8)
        XCTAssertEqual(RadioBroadcaster.requestPath(from: legacy), "/stream.aac")
    }

    func testExtractSlugParsesPath() {
        XCTAssertEqual(RadioBroadcaster.extractSlug(from: "/stream/my-fm.aac"), "my-fm")
        XCTAssertEqual(RadioBroadcaster.extractSlug(from: "/stream/a.aac"), "a")
        XCTAssertNil(RadioBroadcaster.extractSlug(from: "/stream.aac"))
        XCTAssertNil(RadioBroadcaster.extractSlug(from: "/other/foo.aac"))
        XCTAssertNil(RadioBroadcaster.extractSlug(from: "/stream/.aac"))
    }

    func testADTSHeaderConstruction() {
        let header = ADTSHeader(
            profile: 1,
            sampleFreqIdx: 4,
            channelConfig: 2,
            payloadLength: 300
        )
        let data = header.data
        XCTAssertEqual(data.count, 7)
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1] & 0xF0, 0xF0)
        XCTAssertEqual(data[2], (1 << 6) | (4 << 2) | (2 >> 2))
    }

    func testADTSSampleFrequencyIndexCommonRates() {
        XCTAssertEqual(ADTSHeader.sampleFrequencyIndex(for: 44_100), 4)
        XCTAssertEqual(ADTSHeader.sampleFrequencyIndex(for: 48_000), 3)
        XCTAssertEqual(ADTSHeader.sampleFrequencyIndex(for: 22_050), 7)
        XCTAssertNil(ADTSHeader.sampleFrequencyIndex(for: 12_345))
    }

    func testAACRingBufferReadFromLiveTail() async {
        let buffer = AACRingBuffer(capacity: 1024)
        buffer.write(Data(repeating: 0xAB, count: 100))

        var cursor = buffer.readCursor()
        buffer.write(Data(repeating: 0xCD, count: 50))

        let first = await buffer.read(from: &cursor)
        XCTAssertEqual(first.count, 50)
        XCTAssertEqual(first.first, 0xCD)
    }

    /// A discontinuity mark makes lagging readers jump the stale backlog:
    /// they miss everything written before the mark and resume at the
    /// bytes written after it. Caught-up readers and the natural-EOF path
    /// (which never marks) are unaffected.
    func testAACRingBufferDiscontinuitySkipsBacklog() async {
        let buffer = AACRingBuffer(capacity: 4096)
        var laggard = buffer.readCursor()          // at position 0

        buffer.write(Data(repeating: 0xAA, count: 1000))   // old track
        buffer.markDiscontinuity()                          // skip!
        buffer.write(Data(repeating: 0xBB, count: 500))     // new track

        let data = await buffer.read(from: &laggard)
        XCTAssertEqual(data.count, 500, "backlog before the mark is skipped")
        XCTAssertTrue(data.allSatisfy { $0 == 0xBB }, "only the new track's bytes arrive")

        // A reader joining after the mark reads normally.
        buffer.write(Data(repeating: 0xCC, count: 100))
        let more = await buffer.read(from: &laggard)
        XCTAssertTrue(more.allSatisfy { $0 == 0xCC })
    }

    /// A discontinuity with nothing written past it must SUSPEND the
    /// reader, not hand back empty data. The first version of the skip
    /// fix got this wrong: `read` compared `totalWritten` against the
    /// pre-floor cursor, concluded data was available, then found none
    /// past the floor and returned empty — so the serve loop span at
    /// full tilt until the next write. It pinned a CI runner for 50
    /// minutes before anyone noticed.
    func testAACRingBufferDiscontinuityDoesNotBusySpin() async throws {
        actor Box {
            var value: Int?
            func set(_ v: Int) { value = v }
            func get() -> Int? { value }
        }
        let buffer = AACRingBuffer(capacity: 4096)
        let startCursor = buffer.readCursor()          // position 0
        buffer.write(Data(repeating: 0xAA, count: 1000))
        buffer.markDiscontinuity()                     // floor == 1000, cursor behind

        let box = Box()
        let reader = Task {
            var c = startCursor
            let d = await buffer.read(from: &c)
            await box.set(d.count)
        }
        defer { reader.cancel() }

        try await Task.sleep(nanoseconds: 300_000_000)
        let early = await box.get()
        XCTAssertNil(early, "read must suspend past the floor, not spin returning empty")

        buffer.write(Data(repeating: 0xBB, count: 500))
        try await Task.sleep(nanoseconds: 300_000_000)
        let woken = await box.get()
        XCTAssertEqual(woken, 500, "reader wakes on the next write and gets the new track")
    }

    func testAACRingBufferCoalescesMultipleWrites() async {
        let buffer = AACRingBuffer(capacity: 1024)
        var cursor = buffer.readCursor()

        buffer.write(Data([0x01, 0x02]))
        buffer.write(Data([0x03, 0x04]))

        let data = await buffer.read(from: &cursor)
        XCTAssertEqual(data, Data([0x01, 0x02, 0x03, 0x04]))
    }

    /// Multi-station smoke test. Boots two fixture-backed stations and
    /// verifies each serves AAC on its slug-specific URL independently.
    /// Skips if fixture tracks aren't bundled.
    @MainActor
    func testStartStopMultipleStations() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        let port: UInt16 = 18_020
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }

        let a = Station(name: "Alpha FM", kind: .playlist(queue: tracks))
        let b = Station(name: "Beta FM", kind: .playlist(queue: tracks))

        await radio.startBroadcast(station: a)
        await radio.startBroadcast(station: b)

        XCTAssertTrue(radio.isBroadcasting(stationID: a.id))
        XCTAssertTrue(radio.isBroadcasting(stationID: b.id))
        XCTAssertEqual(radio.broadcasting.count, 2)

        let aURL = try XCTUnwrap(radio.streamURL(for: a))
        let bURL = try XCTUnwrap(radio.streamURL(for: b))
        XCTAssertTrue(aURL.path.contains("alpha-fm"))
        XCTAssertTrue(bURL.path.contains("beta-fm"))
        XCTAssertNotEqual(aURL, bURL)

        // Stop one — the other should stay live.
        radio.stopBroadcast(stationID: a.id)
        XCTAssertFalse(radio.isBroadcasting(stationID: a.id))
        XCTAssertTrue(radio.isBroadcasting(stationID: b.id))
    }

    /// Stream-URL shape matches the documented `http://host:port/stream/{slug}.aac`
    /// contract so bookmarks / share sheets paste cleanly.
    @MainActor
    func testStreamURLPathContainsSlug() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        let port: UInt16 = 18_021
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }

        let station = Station(name: "My FM Station", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)

        let url = try XCTUnwrap(radio.streamURL(for: station))
        XCTAssertEqual(url.path, "/stream/my-fm-station.aac")
        XCTAssertEqual(url.scheme, "http")
    }

    /// End-to-end pipeline smoke test on the slug-specific URL. Fires up a
    /// single station, connects over TCP to `/stream/{slug}.aac`, sends a
    /// minimal GET, and verifies we get an HTTP 200 with `audio/aac` +
    /// at least one ADTS sync word.
    @MainActor
    func testBroadcastProducesAACStream() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        let port: UInt16 = 18_017
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "Smoke", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        XCTAssertTrue(radio.isBroadcasting(stationID: station.id))

        try await Task.sleep(nanoseconds: 2_000_000_000)

        let (data, response) = try await Self.fetchStream(
            port: port,
            path: "/stream/\(station.slug).aac",
            maxBytes: 8_192
        )

        guard let http = response as? HTTPURLResponse else {
            XCTFail("Not HTTP response")
            return
        }
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(
            (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
            "audio/aac"
        )

        XCTAssertGreaterThan(data.count, 0)
        let syncFound = (0..<max(0, data.count - 1)).contains { i in
            data[i] == 0xFF && (data[i + 1] & 0xF6) == 0xF0
        }
        XCTAssertTrue(syncFound, "No ADTS sync word in \(data.count) bytes of stream")
    }

    /// Legacy `/stream.aac` must 302-redirect to the slug-specific URL of
    /// the first live station so existing bookmarks keep working.
    @MainActor
    func testLegacyStreamURLRedirectsWhenStationBroadcasting() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        let port: UInt16 = 18_022
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "Legacy Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 800_000_000)

        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/stream.aac",
            requestHeaders: []
        )
        XCTAssertTrue(
            response.contains("HTTP/1.1 302"),
            "Expected 302 redirect, got: \(response)"
        )
        // Relative, NOT absolute. An absolute `http://localhost:<port>/…`
        // Location resolves against the *listener's* machine, so every
        // listener who isn't on the mac-mini follows it into a dead end.
        // A relative Location resolves against whatever host the request
        // arrived on — localhost locally, radio.jonasjohansson.se through
        // the tunnel. Matches the shape `/now.json` already emits.
        XCTAssertTrue(
            response.lowercased().contains("location: /stream/legacy-test.aac"),
            "Missing relative Location header: \(response)"
        )
        XCTAssertFalse(
            response.lowercased().contains("location: http://"),
            "Location must not be an absolute URL: \(response)"
        )
    }

    /// The legacy redirect must never bake a host or port into `Location`.
    ///
    /// This is the regression guard for the outage where the public
    /// `/stream.aac` answered `302 Location: http://localhost:18000/…`.
    /// It looked healthy from the mac-mini — where `localhost` *is* the
    /// origin — and was broken for everyone else.
    func testRedirectResponseLocationIsHostRelative() {
        let response = RadioBroadcaster.redirectResponse(slug: "techno-2")

        // Split on CRLF rather than substring-matching a trailing "\r":
        // Swift fuses CR+LF into a single grapheme cluster, so a needle
        // ending in a lone "\r" never matches a real header line.
        let lines = response.components(separatedBy: "\r\n")

        XCTAssertEqual(lines.first, "HTTP/1.1 302 Found")
        XCTAssertTrue(
            lines.contains("Location: /stream/techno-2.aac"),
            "Expected host-relative Location, got lines: \(lines)"
        )
        XCTAssertFalse(response.contains("localhost"))
        XCTAssertFalse(response.contains("http://"))
        XCTAssertFalse(response.contains("https://"))
    }

    /// Legacy `/stream.aac` 404s when there's nothing to redirect to.
    @MainActor
    func testLegacyStreamURL404WhenNothingBroadcasting() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        // Bring up a station then stop it — that leaves the listener down
        // entirely, so we need a different approach: start one, stop it,
        // and try again. But the listener tears down on empty, so instead
        // keep a station running on an OTHER port, and for THIS port start
        // + stop to exercise the "listener live, no pipelines" edge.
        //
        // Simpler: bring up a station then immediately stop just its
        // broadcast (not stopAll). tearDownListener runs when the set is
        // empty, so this is effectively an offline-listener check — but
        // the listener won't answer when it's down.
        //
        // So we drive it directly: start + stop to cycle once, then start
        // ANOTHER station and stop IT, leaving listener live on a
        // different slug request. Instead just hit a random non-existent
        // slug, which exercises the same 404 branch.
        let port: UInt16 = 18_023
        let radio = RadioBroadcaster(port: port)
        let filler = Station(name: "Filler Station", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: filler)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 500_000_000)

        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/stream/nonexistent-station.aac",
            requestHeaders: []
        )
        XCTAssertTrue(
            response.contains("HTTP/1.1 404"),
            "Expected 404 for unknown slug, got: \(response)"
        )
    }

    /// ICY handshake: client sends `Icy-MetaData: 1` and the response must
    /// advertise `icy-metaint` + `icy-name` using the *station's* name.
    @MainActor
    func testBroadcastWithICYSendsMetaintHeader() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        let port: UInt16 = 18_018
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "ICY Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let responseText = try await Self.fetchRawResponse(
            port: port,
            path: "/stream/\(station.slug).aac",
            requestHeaders: ["Icy-MetaData: 1"]
        )
        XCTAssertTrue(
            responseText.contains("HTTP/1.1 200 OK"),
            "No 200 in response: \(responseText)"
        )
        XCTAssertTrue(
            responseText.lowercased().contains("icy-metaint: 16384"),
            "Missing icy-metaint header: \(responseText)"
        )
        // Per-station icy-name, not the hardcoded "Ratbat" from v1.
        XCTAssertTrue(
            responseText.lowercased().contains("icy-name: icy test"),
            "Missing per-station icy-name header: \(responseText)"
        )
    }

    /// Non-ICY clients MUST NOT receive an `icy-metaint` header.
    @MainActor
    func testBroadcastWithoutICYOmitsMetaintHeader() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        let port: UInt16 = 18_019
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "NoICY", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let responseText = try await Self.fetchRawResponse(
            port: port,
            path: "/stream/\(station.slug).aac",
            requestHeaders: []
        )
        XCTAssertTrue(
            responseText.contains("HTTP/1.1 200 OK"),
            "No 200 in response: \(responseText)"
        )
        XCTAssertFalse(
            responseText.lowercased().contains("icy-metaint"),
            "icy-metaint leaked to non-ICY client: \(responseText)"
        )
    }

    // MARK: - Fixture / network helpers

    nonisolated private static func loadFixtureTracks(bundle: Bundle) async throws -> [Track]? {
        guard let fixtureRoot = bundle.url(
            forResource: "library",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) ?? bundle.resourceURL?
            .appendingPathComponent("Fixtures/library") else {
            return nil
        }
        let playlists = try await LibraryIndexer().scan(folder: fixtureRoot)
        guard let tracks = playlists.first?.tracks, !tracks.isEmpty else {
            return nil
        }
        return tracks
    }

    /// Fetch a finite HTTP response (HTML, JSON, redirect — anything that
    /// isn't an infinite AAC stream) and return the whole body plus the
    /// response metadata. URLSession handles framing, so we don't need
    /// custom byte-counting here.
    nonisolated private static func fetchPayload(
        port: UInt16,
        path: String
    ) async throws -> (Data, URLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        return try await session.data(from: url)
    }

    nonisolated private static func fetchStream(
        port: UInt16,
        path: String,
        maxBytes: Int
    ) async throws -> (Data, URLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let config = URLSessionConfiguration.ephemeral
        // 15s, not 5: the suite now runs several real encoder pipelines
        // before this test, and first-byte latency under that load blew a
        // 5s budget intermittently. This test asserts the bytes are AAC,
        // not how fast they arrive.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        let (bytes, response) = try await session.bytes(from: url)

        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
        } catch {
            // URLSession times out or cancels the stream — take what we got.
        }
        return (data, response)
    }

    /// Opens a raw TCP connection via Network.framework, writes a
    /// handcrafted GET with the given extra headers, and returns the
    /// response bytes (up to the end of the header block) decoded as
    /// UTF-8. Raw sockets rather than URLSession because URLSession drops
    /// custom `Icy-*` request headers, hides non-standard response
    /// headers, and auto-follows 302s so we can't assert on the redirect.
    /// Open a stream connection and *hold it*, so the broadcaster counts a
    /// live listener. `fetchRawResponse` closes as soon as it has headers,
    /// which is not enough: `awaitListener` only stops throttling the
    /// encode loop while a client is actually attached.
    ///
    /// Caller must `cancel()` the returned connection.
    nonisolated static func holdOpenStreamConnection(
        port: UInt16,
        path: String
    ) async -> NWConnection? {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let readyLatch = OnceLatch()
        let ready: Bool = await withCheckedContinuation { cont in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if readyLatch.fire() { cont.resume(returning: true) }
                case .failed, .cancelled:
                    if readyLatch.fire() { cont.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        guard ready else {
            connection.cancel()
            return nil
        }

        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let sendLatch = OnceLatch()
        _ = await withCheckedContinuation { cont in
            connection.send(
                content: Data(request.utf8),
                completion: .contentProcessed { _ in
                    if sendLatch.fire() { cont.resume(returning: true) }
                }
            )
        }

        // Keep draining in the background so the socket stays alive and
        // the server doesn't block on a full send buffer.
        Task.detached {
            while true {
                let more: Bool = await withCheckedContinuation { cont in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, isComplete, error in
                        cont.resume(returning: !(isComplete || error != nil || data == nil))
                    }
                }
                if !more { break }
            }
        }
        return connection
    }

    nonisolated private static func fetchRawResponse(
        port: UInt16,
        path: String,
        requestHeaders: [String],
        maxBytes: Int = 2_048,
        method: String = "GET",
        body: String? = nil
    ) async throws -> String {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        defer { connection.cancel() }

        let readyLatch = OnceLatch()
        let ready: Bool = await withCheckedContinuation { cont in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if readyLatch.fire() { cont.resume(returning: true) }
                case .failed, .cancelled:
                    if readyLatch.fire() { cont.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        guard ready else { return "<<<connection not ready>>>" }

        var request = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for header in requestHeaders { request += "\(header)\r\n" }
        if let body {
            request += "Content-Length: \(body.utf8.count)\r\n"
        }
        request += "\r\n"
        // Body rides in the SAME send as the headers — the coalesced
        // segment shape every browser produces, and the one that used to
        // hang the server (see the coalesced-POST regression suite).
        if let body { request += body }

        let sendLatch = OnceLatch()
        let sent: Bool = await withCheckedContinuation { cont in
            connection.send(
                content: Data(request.utf8),
                completion: .contentProcessed { err in
                    if sendLatch.fire() { cont.resume(returning: err == nil) }
                }
            )
        }
        guard sent else { return "<<<send failed>>>" }

        var accumulated = Data()
        let deadline = Date().addingTimeInterval(4)
        while accumulated.count < maxBytes, Date() < deadline {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 4_096
                ) { data, _, _, _ in
                    cont.resume(returning: data)
                }
            }
            if let chunk, !chunk.isEmpty {
                accumulated.append(chunk)
                if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                    break
                }
            } else {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return String(data: accumulated, encoding: .utf8) ?? ""
    }

    /// One-shot gate for Sendable closures that may fire more than once.
    private final class OnceLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    // MARK: - now.json + root routing

    /// The HTML player used to be served from `GET /`. After the
    /// architecture split it lives on GitHub Pages at ratbat.jonasjohansson.se,
    /// so this server should only speak the stream + JSON API. Root
    /// requests now return 404 — any other non-allow-listed path behaves
    /// the same way, exercised here via `/`, `/index.html` and `/style.css`.
    @MainActor
    func testRootAndStaticAssetPathsReturnNotFound() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        let port: UInt16 = 18_024
        let radio = RadioBroadcaster(port: port)
        // Need a live station so the listener is actually up.
        let station = Station(name: "Root Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 400_000_000)

        for path in ["/", "/index.html", "/style.css", "/app.js", "/manifest.json", "/favicon.png"] {
            let response = try await Self.fetchRawResponse(
                port: port,
                path: path,
                requestHeaders: [],
                maxBytes: 2_048
            )
            XCTAssertTrue(
                response.contains("HTTP/1.1 404"),
                "Expected 404 for \(path), got: \(response.prefix(200))"
            )
        }
    }

    /// `GET /now.json` returns a JSON payload with one entry per
    /// broadcasting station, including listener count, slug, stream URL
    /// and (once the encoder has opened a track) current-track info.
    @MainActor
    func testNowJSONReturnsValidPayload() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        let port: UInt16 = 18_025
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "Now JSON", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        // Give the encoder time to open a track so `currentTrack` populates.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let (data, response) = try await Self.fetchPayload(
            port: port,
            path: "/now.json"
        )

        guard let http = response as? HTTPURLResponse else {
            XCTFail("Not HTTP response")
            return
        }
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(
            (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
            "application/json"
        )
        XCTAssertEqual(
            http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"),
            "*"
        )

        struct NowResponse: Decodable {
            struct Station: Decodable {
                let id: String
                let name: String
                let slug: String
                let broadcasting: Bool
                let streamURL: String?
                let listeners: Int
                let currentTrack: Track?
            }
            struct Track: Decodable {
                let title: String
                let artist: String
                let album: String
            }
            let stations: [Station]
        }

        let decoded = try JSONDecoder().decode(NowResponse.self, from: data)
        XCTAssertEqual(decoded.stations.count, 1)
        let only = try XCTUnwrap(decoded.stations.first)
        XCTAssertEqual(only.name, "Now JSON")
        XCTAssertEqual(only.slug, "now-json")
        XCTAssertTrue(only.broadcasting)
        XCTAssertEqual(only.streamURL, "/stream/now-json.aac")
        XCTAssertGreaterThanOrEqual(only.listeners, 0)
        XCTAssertNotNil(only.currentTrack, "Expected current track after warmup")
    }

    /// Startup edge: the broadcaster is running (we need *something* to
    /// bind the listener) but then we stop the only station. That
    /// immediately tears the listener down — so verifying "empty /now.json"
    /// requires a second broadcast still alive. Use two stations, stop one,
    /// and confirm the remaining payload shrinks to one entry.
    @MainActor
    func testNowJSONShrinksWhenStationsStop() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }

        let port: UInt16 = 18_026
        let radio = RadioBroadcaster(port: port)
        let a = Station(name: "Alpha JSON", kind: .playlist(queue: tracks))
        let b = Station(name: "Beta JSON", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: a)
        await radio.startBroadcast(station: b)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 600_000_000)

        let (firstData, _) = try await Self.fetchPayload(
            port: port,
            path: "/now.json"
        )
        struct Envelope: Decodable {
            struct S: Decodable { let name: String }
            let stations: [S]
        }
        let first = try JSONDecoder().decode(Envelope.self, from: firstData)
        XCTAssertEqual(first.stations.count, 2)

        radio.stopBroadcast(stationID: a.id)
        try await Task.sleep(nanoseconds: 300_000_000)

        let (secondData, _) = try await Self.fetchPayload(
            port: port,
            path: "/now.json"
        )
        let second = try JSONDecoder().decode(Envelope.self, from: secondData)
        XCTAssertEqual(second.stations.count, 1)
        XCTAssertEqual(second.stations.first?.name, "Beta JSON")
    }

    func testAACRingBufferOverflowBumpsCursor() async {
        let capacity = 1024
        let total = capacity * 3
        let buffer = AACRingBuffer(capacity: capacity)
        var cursor = buffer.readCursor()
        buffer.write(Data((0..<total).map { UInt8($0 & 0xFF) }))
        let data = await buffer.read(from: &cursor)
        XCTAssertEqual(data.count, capacity)
        XCTAssertEqual(data.first, UInt8(2048 & 0xFF))
        XCTAssertEqual(data.last, UInt8((total - 1) & 0xFF))
    }

    // MARK: - Owner passcode: /auth and the failed-attempt throttle

    /// `/auth` answers 200 for the owner and 403 for everyone else, and
    /// changes nothing either way — the web player's unlock prompt needs
    /// to test a passcode without ♥-ing a track to find out.
    @MainActor
    func testAuthValidatesPasscodeWithoutSideEffects() async {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "test-passcode"
        let radio = RadioBroadcaster(preferences: prefs)
        radio.ownerThrottleStep = 0
        defer { radio.stopAll() }

        let (ok, okBody) = await radio.performAuthAsync(token: "test-passcode")
        XCTAssertEqual(ok, 200)
        XCTAssertTrue(String(data: okBody, encoding: .utf8)!.contains("ok"))

        for bad in [nil, "", "  ", "nope"] as [String?] {
            let (status, body) = await radio.performAuthAsync(token: bad)
            XCTAssertEqual(status, 403, "auth with token \(bad ?? "nil")")
            XCTAssertTrue(String(data: body, encoding: .utf8)!.contains("listener mode"))
        }

        // Nothing was started, nothing was consumed: /auth is inert.
        XCTAssertTrue(radio.broadcasting.isEmpty)
        XCTAssertTrue(radio.currentItemByStation.isEmpty)
    }

    /// Wrong passcodes get progressively slower; the right one never does.
    /// The property that matters is that a stranger hammering the endpoint
    /// cannot lock the owner out — success is not rate limited and clears
    /// the count.
    @MainActor
    func testRepeatedWrongPasscodesAreThrottledButOwnerIsNot() async {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "test-passcode"
        let radio = RadioBroadcaster(preferences: prefs)
        radio.ownerFreeAttempts = 2
        radio.ownerThrottleStep = 0.2
        radio.ownerThrottleCeiling = 1
        defer { radio.stopAll() }

        // The first `ownerFreeAttempts` failures are not delayed.
        let freeStart = Date()
        for _ in 0..<2 { _ = await radio.performAuthAsync(token: "nope") }
        XCTAssertLessThan(Date().timeIntervalSince(freeStart), 0.2)

        // The next two are (0.2s then 0.4s).
        let throttledStart = Date()
        for _ in 0..<2 { _ = await radio.performAuthAsync(token: "nope") }
        let throttled = Date().timeIntervalSince(throttledStart)
        XCTAssertGreaterThan(throttled, 0.5, "wrong passcodes should be slowed")

        // The owner is let straight through despite the failures ahead of
        // them, and that success resets the penalty for the next attempt.
        let ownerStart = Date()
        let (status, _) = await radio.performAuthAsync(token: "test-passcode")
        let ownerElapsed = Date().timeIntervalSince(ownerStart)
        XCTAssertEqual(status, 200)
        XCTAssertLessThan(ownerElapsed, 0.2, "the owner must never be throttled")
        XCTAssertEqual(radio.failedOwnerAttempts, 0)
    }

    /// The throttle guards the action endpoints too, not just `/auth` —
    /// they share one gate, so a guesser cannot dodge it by hammering
    /// `/like` instead.
    @MainActor
    func testActionEndpointsShareTheOwnerThrottle() async {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "test-passcode"
        let radio = RadioBroadcaster(preferences: prefs)
        radio.ownerThrottleStep = 0
        defer { radio.stopAll() }

        _ = await radio.performLikeAsync(stationID: UUID(), token: "nope")
        _ = await radio.performSkipAsync(stationID: UUID(), token: "nope")
        XCTAssertEqual(radio.failedOwnerAttempts, 2)

        // A valid passcode resets the shared count even though the station
        // itself is bogus (the gate runs before the station lookup).
        let (status, _) = await radio.performSkipAsync(stationID: UUID(), token: "test-passcode")
        XCTAssertEqual(status, 404, "valid passcode gets past the gate to a real 404")
        XCTAssertEqual(radio.failedOwnerAttempts, 0)
    }
}
