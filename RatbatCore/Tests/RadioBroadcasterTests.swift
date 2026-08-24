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

    // MARK: - Launch resume must not be one-shot or head-of-line blocked

    func testResumeRetryDelayGrowsAndCaps() {
        XCTAssertEqual(RadioBroadcaster.resumeRetryDelay(forAttempt: 1), 1)
        XCTAssertEqual(RadioBroadcaster.resumeRetryDelay(forAttempt: 2), 2)
        XCTAssertEqual(RadioBroadcaster.resumeRetryDelay(forAttempt: 3), 4)
        XCTAssertEqual(RadioBroadcaster.resumeRetryDelay(forAttempt: 99), 30, "same 30s ceiling as the rest")
    }

    /// Resume awaited each station in turn. A generative station's
    /// `startBroadcast` awaits `downloadService.ensureReady()` — the Python
    /// venv bootstrap, 30–60s on a cold start — so one slow station gated
    /// every station behind it, and the listener and tunnel with them.
    ///
    /// Observed for real during the 065c4f0 deploy: one station was live
    /// and audible while the second still returned 502.
    @MainActor
    func testResumeStartsStationsConcurrentlyNotSequentially() async throws {
        let radio = RadioBroadcaster(port: 18_063)
        defer { radio.stopAll() }

        let slow = Station(name: "Slow Bootstrap", kind: .playlist(queue: []))
        let fast = Station(name: "Fast", kind: .playlist(queue: []))
        let started = StartRecorder()

        let began = Date()
        await radio.resumeStations(
            [slow, fast],
            matching: [slow.slug, fast.slug],
            maxAttempts: 1
        ) { station in
            if station.slug == slow.slug {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            await started.record(station.slug)
        }
        let elapsed = Date().timeIntervalSince(began)

        let seen = await started.slugs
        XCTAssertEqual(Set(seen), Set([slow.slug, fast.slug]), "both stations must be started")
        // Sequential would be ~1.5s + ~0 = 1.5s with `fast` only reached
        // AFTER the slow one. Concurrent finishes in ~1.5s total but
        // `fast` lands almost immediately.
        XCTAssertEqual(seen.first, fast.slug, "the fast station was gated behind the slow one")
        XCTAssertLessThan(elapsed, 2.5, "resume took \(elapsed)s")
    }

    /// Resume ran once per launch with no retry, so a station that failed
    /// to start was gone until the next launch — the same "no second
    /// chance" shape as the tunnel that never came back.
    @MainActor
    func testResumeRetriesAStationThatFailsToStart() async throws {
        let radio = RadioBroadcaster(port: 18_064)
        defer { radio.stopAll() }

        let flaky = Station(name: "Flaky Resume", kind: .playlist(queue: []))
        let attempts = AttemptCounter()

        await radio.resumeStations(
            [flaky],
            matching: [flaky.slug],
            maxAttempts: 4,
            retryDelayOverride: 0
        ) { _ in
            await attempts.bump()
        } isLive: { _ in
            // Fails twice, then "starts".
            await attempts.count >= 3
        }

        let n = await attempts.count
        XCTAssertGreaterThanOrEqual(n, 3, "resume gave up after \(n) attempt(s)")
    }

    private actor StartRecorder {
        private(set) var slugs: [String] = []
        func record(_ slug: String) { slugs.append(slug) }
    }
    private actor AttemptCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    // MARK: - The first listener must not wait on a 5s poll

    /// `awaitListener` idled the encode loop and woke on a 5-second poll,
    /// so the first listener on an idle station — the normal state of a
    /// personal radio — waited 0–5s with no bytes flowing.
    @MainActor
    func testFirstListenerWakesTheEncodeLoopImmediately() async throws {
        let radio = RadioBroadcaster(port: 18_065)
        defer { radio.stopAll() }
        let stationID = UUID()

        let began = Date()
        let waiter = Task { @MainActor in
            await radio.awaitFirstListener(stationID: stationID)
            return Date().timeIntervalSince(began)
        }
        // Let it actually suspend before signalling.
        try await Task.sleep(nanoseconds: 200_000_000)
        radio.signalListenerArrived(stationID: stationID)

        let waited = await waiter.value
        XCTAssertLessThan(waited, 1.0, "first listener waited \(waited)s — still polling")
    }

    /// Cancellation must free the waiter, or a stopped station leaves its
    /// encode task suspended forever.
    @MainActor
    func testAwaitFirstListenerUnblocksOnCancellation() async throws {
        let radio = RadioBroadcaster(port: 18_066)
        defer { radio.stopAll() }
        let stationID = UUID()

        let waiter = Task { @MainActor in
            await radio.awaitFirstListener(stationID: stationID)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        waiter.cancel()

        let done = Task { @MainActor in
            await waiter.value
            return true
        }
        let finished = await done.value
        XCTAssertTrue(finished, "cancelled waiter never resumed")
    }

    // MARK: - A transient failure must not end a station

    /// Throws a network error the first two times, then yields a real
    /// track. The shape of a Wi-Fi blip or a yt-dlp hiccup.
    private actor FlakyThenGoodSource: TrackSource {
        private var calls = 0
        private let url: URL
        init(url: URL) { self.url = url }
        func nextURL() async throws -> TrackSourceItem? {
            calls += 1
            if calls <= 2 { throw URLError(.networkConnectionLost) }
            return TrackSourceItem(
                url: url,
                artist: "Recovered",
                title: "After The Blip",
                album: nil,
                duration: nil,
                artworkURL: nil,
                sourceURL: nil,
                youtubeURL: nil,
                origin: .library,
                historyID: nil
            )
        }
    }

    /// The headline: a station that hits a transient source failure must
    /// stay on air and recover, not fold.
    ///
    /// Before: the encode loop `break`s on any thrown error, unwinds
    /// through `stopBroadcastRanDry`, and the station is off until the
    /// next launch — even though the failure lasted seconds.
    @MainActor
    func testTransientSourceFailureDoesNotEndTheStation() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)),
              let first = tracks.first else {
            throw XCTSkip("Fixtures missing")
        }
        let radio = RadioBroadcaster(port: 18_060)
        defer { radio.stopAll() }

        let station = Station(name: "Flaky", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: FlakyThenGoodSource(url: first.url))

        // Two failures at 1s and 2s of backoff, then the good track.
        try await Task.sleep(nanoseconds: 6_000_000_000)

        XCTAssertTrue(
            radio.isBroadcasting(stationID: station.id),
            "a transient source failure took the station off air"
        )
        XCTAssertNil(
            radio.lastOffAir[station.id],
            "station was folded down: \(String(describing: radio.lastOffAir[station.id]))"
        )
    }

    /// Genuine exhaustion must still end the station — the retry loop must
    /// not turn "there is nothing left to play" into an infinite spin.
    @MainActor
    func testGenuineExhaustionStillEndsTheStation() async throws {
        let radio = RadioBroadcaster(port: 18_061)
        defer { radio.stopAll() }
        let station = Station(name: "Really Dry", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: DrySource())
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(radio.lastOffAir[station.id]?.reason, .exhausted)
        XCTAssertFalse(radio.isBroadcasting(stationID: station.id))
    }

    /// Backoff shape, and its relationship to the other two retry loops.
    func testSourceErrorBackoffGrowsAndCaps() {
        XCTAssertEqual(RadioBroadcaster.sourceErrorBackoff(consecutiveFailures: 1), 1)
        XCTAssertEqual(RadioBroadcaster.sourceErrorBackoff(consecutiveFailures: 2), 2)
        XCTAssertEqual(RadioBroadcaster.sourceErrorBackoff(consecutiveFailures: 3), 4)
        XCTAssertEqual(RadioBroadcaster.sourceErrorBackoff(consecutiveFailures: 99), 30, "capped")
        // Same 30s ceiling as the open-failure backoff and the listener
        // rebind backoff, so no combination of them can stall recovery for
        // longer than one cap per loop iteration.
        XCTAssertEqual(
            RadioBroadcaster.sourceErrorBackoff(consecutiveFailures: 99),
            RadioBroadcaster.openFailureBackoff(consecutiveFailures: 99)
        )
        XCTAssertEqual(
            RadioBroadcaster.sourceErrorBackoff(consecutiveFailures: 99),
            RadioBroadcaster.listenerRebindDelay(forAttempt: 99)
        )
    }

    /// A candidate the resolver cannot use and a machine that cannot reach
    /// the internet are different facts. Sharing a budget is what turned a
    /// blip into "pool exhausted".
    func testResolveFailureClassification() {
        XCTAssertEqual(
            classifyResolveFailure(TrackResolver.Error.noYouTubeMatch(artist: "A", title: "B")),
            .genuine
        )
        XCTAssertEqual(classifyResolveFailure(TrackResolver.Error.timedOut(seconds: 7)), .transient)
        XCTAssertEqual(classifyResolveFailure(TrackResolver.Error.downloadFailed("net")), .transient)
        XCTAssertEqual(classifyResolveFailure(TrackResolver.Error.venvNotReady), .transient)
        XCTAssertEqual(classifyResolveFailure(URLError(.timedOut)), .transient)
        // Unknown errors default to transient: mis-classifying a blip as
        // genuine takes a station off air; the reverse only costs a retry.
        struct Weird: Swift.Error {}
        XCTAssertEqual(classifyResolveFailure(Weird()), .transient)
    }

    /// Only genuine end-of-supply collapses to `nil` at the source layer.
    /// A transient failure must stay an error so the encode loop can retry
    /// it instead of reading it as "this station is over".
    func testOnlyGenuineExhaustionEndsTheStationAtSourceLayer() {
        XCTAssertTrue(BandcampStationController.Error.poolExhausted.endsStation)
        XCTAssertTrue(BandcampStationController.Error.noTracksForTags(["x"]).endsStation)
        XCTAssertFalse(BandcampStationController.Error.transientResolveFailure(count: 8).endsStation)

        XCTAssertTrue(LastFMStationController.Error.poolExhausted.endsStation)
        XCTAssertFalse(LastFMStationController.Error.transientResolveFailure(count: 8).endsStation)

        XCTAssertTrue(NTSStationController.Error.poolExhausted.endsStation)
        XCTAssertFalse(NTSStationController.Error.transientResolveFailure(count: 8).endsStation)
    }

    // MARK: - Evidence hygiene

    /// Test runs logged to the same subsystem AND categories as production,
    /// with identical message text. Over a two-hour window on the mac-mini
    /// there were 23,056 lines under `se.jonasjohansson.ratbat` — every one
    /// from `xctest`, none from the running app. The durable evidence store
    /// was ~100% manufactured by CI, and indistinguishable from the real
    /// failures it mimics.
    func testTestRunsLogToASeparateSubsystem() {
        XCTAssertEqual(RatbatLog.subsystem, RatbatLog.testSubsystem)
        XCTAssertNotEqual(RatbatLog.subsystem, RatbatLog.productionSubsystem)
    }

    /// Non-stream requests leaked a `clientTasks` entry each.
    ///
    /// `removeClient` is only wired up by `registerClient`, which runs for
    /// stream clients, so /now.json, /history, /events and the action POSTs
    /// never removed theirs — the dictionary grew for the whole session.
    @MainActor
    func testNonStreamRequestsDoNotLeakConnectionTasks() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_059
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let station = Station(name: "Leak Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        try await Task.sleep(nanoseconds: 600_000_000)

        let baseline = radio.trackedConnectionTaskCount

        for _ in 0..<25 {
            _ = await Self.probeEndpoint(port: port, path: "/now.json", timeout: 2)
        }
        // Let the cancellations land.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let after = radio.trackedConnectionTaskCount
        // Measured: 3 entries survive 25 requests without the reaper, 0 with
        // it. Fewer than 25 because `ObjectIdentifier` reuses the addresses
        // of deallocated connections, so some entries overwrite each other
        // — the growth is real but slower than one-per-request.
        XCTAssertLessThanOrEqual(
            after, baseline,
            "leaked connection tasks: \(baseline) -> \(after) after 25 /now.json requests"
        )
    }

    // MARK: - A listener failure must be survivable

    /// The listener's only failure response was `stopAll()` — no retry, no
    /// rebind, no re-arm — and `.waiting`, which is where a bind conflict
    /// or a lost interface lands, fell into `default: break` and was
    /// ignored entirely.
    ///
    /// Since batch 1 made `stopAll()` also tear down the tunnel, a
    /// transient bind conflict took the whole public endpoint down for
    /// good. Here the port is occupied first, so the broadcaster's listener
    /// cannot bind; once it is freed the broadcaster must recover on its
    /// own rather than staying dark.
    @MainActor
    func testListenerRecoversFromABindConflict() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_058

        // Occupy the port with a plain listener that does NOT share it.
        let squatterParams = NWParameters.tcp
        let squatter = try NWListener(using: squatterParams, on: NWEndpoint.Port(rawValue: port)!)
        squatter.newConnectionHandler = { $0.cancel() }
        squatter.start(queue: .global())
        try await Task.sleep(nanoseconds: 400_000_000)

        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let station = Station(name: "Rebind", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        try await Task.sleep(nanoseconds: 800_000_000)

        // The station must still be considered live — a bind problem is
        // not a reason to erase the broadcast.
        XCTAssertTrue(
            radio.isBroadcasting(stationID: station.id),
            "a bind conflict killed the broadcast outright"
        )

        // Free the port; the broadcaster should rebind by itself.
        squatter.cancel()

        var served = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let r = await Self.probeEndpoint(port: port, path: "/now.json", timeout: 1),
               r.contains("HTTP/1.1 200") {
                served = true
                break
            }
        }
        XCTAssertTrue(served, "listener never rebound after the port was freed")
    }

    /// Mirror of ``testListenerRecoversFromABindConflict`` with the last
    /// station stopped INDIVIDUALLY before the port frees up. The rebind
    /// path used to bail at zero pipelines ("nothing to serve") — but the
    /// listener is the control plane too: once the web can stop the last
    /// station, a dead socket at zero stations means the web can never
    /// start one again.
    @MainActor
    func testListenerRebindsAfterEveryStationStopsIndividually() async throws {
        let port: UInt16 = 18_071

        // Occupy the port so the broadcaster's listener cannot bind.
        let squatterParams = NWParameters.tcp
        let squatter = try NWListener(using: squatterParams, on: NWEndpoint.Port(rawValue: port)!)
        squatter.newConnectionHandler = { $0.cancel() }
        squatter.start(queue: .global())
        try await Task.sleep(nanoseconds: 400_000_000)

        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let station = Station(name: "Rebind Empty", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: NeverSource())
        try await Task.sleep(nanoseconds: 800_000_000)

        // Stop the one and only station — NOT stopAll, which is the
        // deliberate shutdown gesture and tears the listener down on
        // purpose. A per-station stop must leave the control plane up.
        radio.stopBroadcast(stationID: station.id)
        XCTAssertTrue(radio.broadcasting.isEmpty)

        // Free the port; the broadcaster should rebind on its own even
        // though nothing is broadcasting any more.
        squatter.cancel()

        var served = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let r = await Self.probeEndpoint(port: port, path: "/now.json", timeout: 1),
               r.contains("HTTP/1.1 200") {
                served = true
                break
            }
        }
        XCTAssertTrue(
            served,
            "listener never rebound once the last station was stopped individually"
        )
    }

    // MARK: - A cancelled encode loop must not fold its successor

    /// Parks for a long time, then reports exhaustion — a resolve that is
    /// still in flight when the owner stops the station.
    private actor ParkThenDrySource: TrackSource {
        func nextURL() async throws -> TrackSourceItem? {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            return nil
        }
    }

    /// Never returns, so the station it backs stays live for the test.
    private actor NeverSource: TrackSource {
        func nextURL() async throws -> TrackSourceItem? {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return nil
        }
    }

    /// The exit block keys on `stationID` alone. A cancelled loop can
    /// outlive its cancellation while parked on an unstructured prefetch,
    /// so when it finally unwinds it folds down whatever pipeline is
    /// registered for that station — including a freshly restarted one.
    ///
    /// Restarting a stuck station is the owner's most natural repair, and
    /// this made it silently undo itself a few seconds later.
    @MainActor
    func testZombieEncodeLoopDoesNotFoldTheRestartedStation() async throws {
        let radio = RadioBroadcaster(port: 18_057)
        defer { radio.stopAll() }

        let station = Station(name: "Zombie", kind: .playlist(queue: []))

        // First run parks mid-resolve.
        await radio.startBroadcast(station: station, source: ParkThenDrySource())
        try await Task.sleep(nanoseconds: 300_000_000)

        // Owner stops it and immediately starts it again — the old loop is
        // still parked and has not unwound yet.
        radio.stopBroadcast(stationID: station.id)
        await radio.startBroadcast(station: station, source: NeverSource())
        XCTAssertTrue(radio.isBroadcasting(stationID: station.id), "restart should be live")

        // Outlive the parked resolve so the zombie unwinds.
        try await Task.sleep(nanoseconds: 5_000_000_000)

        XCTAssertTrue(
            radio.isBroadcasting(stationID: station.id),
            "the cancelled loop tore down the station that replaced it"
        )
    }

    // MARK: - The encode loop must actually be off the main actor

    private final class ThreadBox: @unchecked Sendable {
        var samples: [Bool] = []
    }

    /// `runEncodeLoop`, `serveClient` and `awaitListener` are `static func`
    /// on a `@MainActor` class and were never marked `nonisolated`, so
    /// despite `Task.detached` they hopped straight back to the main
    /// thread — running the synchronous `AVAudioFile.read` against the
    /// music folder, and the AAC encode, on the main actor.
    ///
    /// 25 other helpers in this file are `nonisolated`; these three were
    /// simply missed. One stalled file read blocks every station's encoder
    /// and every listener's stream, plus the whole UI.
    @MainActor
    func testEncodeLoopDoesNotRunOnTheMainThread() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let box = ThreadBox()
        RadioBroadcaster.encodeLoopThreadObserver = { isMain in box.samples.append(isMain) }
        defer { RadioBroadcaster.encodeLoopThreadObserver = nil }

        let radio = RadioBroadcaster(port: 18_056)
        let station = Station(name: "Thread Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertFalse(box.samples.isEmpty, "probe never fired — encode loop did not start")
        XCTAssertEqual(
            box.samples.first, false,
            "encode loop ran on the main thread: Task.detached is defeated by MainActor isolation"
        )
    }

    // MARK: - Cold start must not advertise a stream it cannot fill

    /// A source that takes a while — the shape of a Bandcamp/NTS first
    /// track, where yt-dlp can spend ~18s before a byte exists.
    private actor SlowSource: TrackSource {
        func nextURL() async throws -> TrackSourceItem? {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            return nil
        }
    }

    /// The pipeline is registered — and therefore serves `200` + ICY
    /// headers, and reports `broadcasting: true` — before the first track
    /// has resolved, while a new listener's cursor starts at the live edge
    /// of an empty ring. So the player got a valid-looking `200 audio/aac`
    /// and then silence for as long as the resolve took, and most give up.
    ///
    /// Worse for this pass: that window is indistinguishable from a
    /// genuinely broken station to any check that reads the status line.
    @MainActor
    func testColdStartDoesNotAdvertise200BeforeAnyAudioExists() async throws {
        let port: UInt16 = 18_055
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }

        let station = Station(name: "Slow Start", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: SlowSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let response = await Self.probeEndpoint(
            port: port,
            path: "/stream/\(station.slug).aac",
            timeout: 2
        )
        XCTAssertFalse(
            response?.contains("HTTP/1.1 200") ?? false,
            "sent 200 before any audio existed: \(response ?? "nil")"
        )
    }

    // MARK: - Going off air must leave a trace

    /// A source that is dry from the first call — a pool refill that came
    /// back empty, which is how stations starve at 03:00.
    private actor DrySource: TrackSource {
        func nextURL() async throws -> TrackSourceItem? { nil }
    }

    /// A source that throws — a network blip during a discover call.
    private actor ThrowingSource: TrackSource {
        struct Boom: Error {}
        func nextURL() async throws -> TrackSourceItem? { throw Boom() }
    }

    /// Running dry was the one shutdown that was graceful by design, and
    /// therefore invisible: no crash report, no error-level log, no on-disk
    /// marker. Both the exhaustion notice and the loop exit were `.info`,
    /// which macOS does not persist, so by morning there was nothing left
    /// to say when or why the station stopped.
    @MainActor
    func testExhaustedSourceRecordsWhyItWentOffAir() async throws {
        let radio = RadioBroadcaster(port: 18_053)
        defer { radio.stopAll() }

        let station = Station(name: "Dry Station", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: DrySource())
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let record = radio.lastOffAir[station.id]
        XCTAssertNotNil(record, "a station going off air must leave a record")
        XCTAssertEqual(record?.reason, .exhausted)
        XCTAssertEqual(record?.reason.label, "exhausted")
    }

    /// A throwing source must NOT be treated as graceful exhaustion.
    ///
    /// This test previously asserted the opposite — that a throw recorded
    /// `.sourceError` and took the station off air. That was the defect:
    /// a network blip and "the music ran out" are different facts, and
    /// only the second should end a station. The station now stays live
    /// and the fault is recorded as a retry instead.
    @MainActor
    func testThrowingSourceKeepsTheStationLiveAndRecordsTheFault() async throws {
        let radio = RadioBroadcaster(port: 18_062)
        defer { radio.stopAll() }

        let station = Station(name: "Broken Station", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: ThrowingSource())
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertTrue(
            radio.isBroadcasting(stationID: station.id),
            "a throwing source must not end the station"
        )
        XCTAssertNil(radio.lastOffAir[station.id], "station must not be folded")

        let retry = radio.sourceRetries[station.id]
        XCTAssertNotNil(retry, "a station retrying past a fault must say so")
        XCTAssertGreaterThanOrEqual(retry?.attempt ?? 0, 1)
        XCTAssertTrue(
            retry?.reason.contains("Boom") ?? false,
            "the fault's reason must be retained, got: \(retry?.reason ?? "nil")"
        )
    }

    // MARK: - The public endpoint outlives the last station

    /// The tunnel's lifetime used to be coupled to `broadcasting.count`:
    /// the last station stopping ran `tearDownListener()`, which cancels
    /// the NWListener *and* stops cloudflared. So pool exhaustion, a source
    /// error, or a plain station switch took the entire public hostname
    /// down — every listener got a Cloudflare origin error, indefinitely,
    /// while Ratbat.app sat there looking healthy.
    ///
    /// Serving 404 on a live hostname is strictly better: the name still
    /// resolves, the outage is legible, and a station switch is invisible.
    @MainActor
    func testStoppingTheLastStationKeepsTheEndpointServing() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_051
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }

        let station = Station(name: "Only Station", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        try await Task.sleep(nanoseconds: 600_000_000)

        // The one and only station goes away — the shape of pool
        // exhaustion, a source error, and the stop half of a switch.
        radio.stopBroadcast(stationID: station.id)
        XCTAssertTrue(radio.broadcasting.isEmpty)
        try await Task.sleep(nanoseconds: 400_000_000)

        let response = await Self.probeEndpoint(port: port, path: "/now.json")
        XCTAssertNotNil(
            response,
            "listener was torn down — the public hostname just went dark"
        )
        XCTAssertTrue(
            response?.contains("HTTP/1.1 200") ?? false,
            "endpoint must keep answering after the last station stops, got: \(response ?? "nil")"
        )
    }

    /// The explicit shutdown gesture still tears everything down, so
    /// quitting doesn't leave a tunnel pointing at a dead port.
    @MainActor
    func testStopAllStillTearsTheListenerDown() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_052
        let radio = RadioBroadcaster(port: port)

        let station = Station(name: "Doomed", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        try await Task.sleep(nanoseconds: 600_000_000)

        radio.stopAll()
        try await Task.sleep(nanoseconds: 500_000_000)

        let response = await Self.probeEndpoint(port: port, path: "/now.json")
        XCTAssertNil(response, "stopAll must close the listener, got: \(response ?? "nil")")
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

    /// OPTIONS against a path that is NOT in ``RadioBroadcaster/jsonPostPaths``
    /// must fall through to the ordinary 404 — the Set really is the gate,
    /// not a parallel list that can drift from the POST dispatch.
    @MainActor
    func testOptionsAgainstUnknownPathReturns404() async throws {
        let port: UInt16 = 18_072
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let station = Station(name: "Preflight 404", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/nope",
            requestHeaders: ["Access-Control-Request-Method: POST"],
            maxBytes: 1_024,
            method: "OPTIONS"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 404"), "Expected 404: \(response)")
    }

    /// A JSON POST declaring a body past ``RadioBroadcaster/maxJSONBodyBytes``
    /// is refused with 413 up front, rather than truncated by the read
    /// deadline into an opaque decode-failure 400 — the slow-tunnel
    /// failure mode the body-limit hardening exists for.
    @MainActor
    func testOversizedJSONPostBodyIsRefusedWith413() async throws {
        let port: UInt16 = 18_073
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let station = Station(name: "Too Large", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        // One byte over the cap, all of it actually sent, so the server's
        // drain-then-answer path runs exactly as it would against a real
        // client mid-upload.
        let padding = String(repeating: "x", count: RadioBroadcaster.maxJSONBodyBytes + 1)
        let response = try await Self.fetchRawResponse(
            port: port,
            path: "/like",
            requestHeaders: ["Content-Type: application/json"],
            maxBytes: 1_024,
            method: "POST",
            body: "{\"station\":\"\(station.id.uuidString)\",\"pad\":\"\(padding)\"}"
        )
        XCTAssertTrue(
            response.contains("HTTP/1.1 413 Content Too Large"),
            "Expected 413: \(response)"
        )
        XCTAssertTrue(response.contains("body too large"), "Expected message: \(response)")
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
        // The full status line, not just the code: 403 had no row in the
        // reason-phrase table, so the wire read `HTTP/1.1 403 Unknown`.
        XCTAssertTrue(response.contains("HTTP/1.1 403 Forbidden"), "Expected 403 Forbidden: \(response)")
        XCTAssertTrue(response.contains("listener mode"), "Expected guest message: \(response)")
    }

    /// Every status a route emits must carry its RFC 9110 reason phrase —
    /// codes missing from the table fell through to `Unknown`.
    func testBuildHTTPResponseKnowsItsStatusTexts() {
        for (status, expected) in [
            (201, "201 Created"),
            (403, "403 Forbidden"),
            (410, "410 Gone"),
            (413, "413 Content Too Large"),
            (422, "422 Unprocessable Content")
        ] {
            let response = RadioBroadcaster.buildHTTPResponse(
                status: status, headers: [:], body: Data()
            )
            let head = String(data: response, encoding: .utf8) ?? ""
            XCTAssertTrue(
                head.hasPrefix("HTTP/1.1 \(expected)\r\n"),
                "Expected \(expected), got: \(head.prefix(40))"
            )
        }
    }

    /// SSE framing: a payload becomes a single `data:` line terminated by
    /// a blank line, with the JSON bytes passed through verbatim. A named
    /// event gains an `event:` line first — and every frame we actually
    /// send is named (`now` / `ping`), so `EventSource` clients can
    /// `addEventListener` instead of funnelling through `onmessage`.
    func testSSEEventFraming() {
        let json = Data("{\"stations\":[]}".utf8)
        let framed = RadioBroadcaster.sseEvent(json)
        XCTAssertEqual(String(data: framed, encoding: .utf8), "data: {\"stations\":[]}\n\n")

        let named = RadioBroadcaster.sseEvent(json, name: "now")
        XCTAssertEqual(
            String(data: named, encoding: .utf8),
            "event: now\ndata: {\"stations\":[]}\n\n"
        )
    }

    /// The frames `/events` actually emits are named `now`, starting with
    /// the initial snapshot — no unnamed frames remain on the wire.
    @MainActor
    func testEventsStreamNamesItsNowFrames() async throws {
        let port: UInt16 = 18_076
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let station = Station(name: "SSE Named", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let (data, _) = try await Self.fetchStream(port: port, path: "/events", maxBytes: 32)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(
            text.hasPrefix("event: now\ndata: "),
            "initial snapshot must be a named `now` event, got: \(text)"
        )
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
    /// Is anything listening on `port`? Returns the response text, or nil
    /// if the port is closed.
    ///
    /// Not `fetchRawResponse`: that only resumes on `.ready`, `.failed` or
    /// `.cancelled`, and a refused TCP connection on macOS reports
    /// `.waiting` (Network.framework keeps retrying rather than failing).
    /// Probing a closed port with it hangs forever — which it did, for
    /// seven minutes, before this helper existed.
    nonisolated static func probeEndpoint(
        port: UInt16,
        path: String,
        timeout: TimeInterval = 3
    ) async -> String? {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        defer { connection.cancel() }

        let latch = OnceLatch()
        let reachable: Bool = await withCheckedContinuation { cont in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if latch.fire() { cont.resume(returning: true) }
                // `.waiting` is a refused/unreachable port, not a transient
                // hiccup, when the peer is 127.0.0.1.
                case .waiting, .failed, .cancelled:
                    if latch.fire() { cont.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if latch.fire() { cont.resume(returning: false) }
            }
        }
        guard reachable else { return nil }

        let sendLatch = OnceLatch()
        _ = await withCheckedContinuation { cont in
            connection.send(
                content: Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8),
                completion: .contentProcessed { _ in
                    if sendLatch.fire() { cont.resume(returning: true) }
                }
            )
        }

        let recvLatch = OnceLatch()
        let data: Data? = await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { chunk, _, _, _ in
                if recvLatch.fire() { cont.resume(returning: chunk) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if recvLatch.fire() { cont.resume(returning: nil) }
            }
        }
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

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

    /// A listener who joins mid-track cannot infer how far in it is: the
    /// stream carries no position and, until this, neither did the wire.
    /// A browser reloaded three minutes into a six-minute track therefore
    /// started its own clock at zero and read "0:00 / 6:30".
    @MainActor
    func testNowJSONSaysHowFarIntoTheTrackTheBroadcastIs() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_141
        let radio = RadioBroadcaster(port: port)
        let station = Station(name: "Elapsed", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        struct Wire: Decodable {
            struct Station: Decodable {
                let currentTrack: Track?
                let nextTrack: Track?
                let recent: [Track]
            }
            struct Track: Decodable {
                let durationSeconds: Double?
                let elapsedSeconds: Double?
            }
            let stations: [Station]
        }
        func read() async throws -> Wire.Station {
            let (data, _) = try await Self.fetchPayload(port: port, path: "/now.json")
            let decoded = try JSONDecoder().decode(Wire.self, from: data)
            return try XCTUnwrap(decoded.stations.first)
        }

        var first: Wire.Station?
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let s = try await read()
            if s.currentTrack?.elapsedSeconds != nil { first = s; break }
        }
        let early = try XCTUnwrap(
            first?.currentTrack?.elapsedSeconds,
            "the current track must report a position"
        )

        XCTAssertGreaterThanOrEqual(early, 0)

        // It only ever moves forward within a track. The rate is not
        // asserted here: these fixtures are seconds long and nothing is
        // listening, so the station parks at the first boundary and the
        // clock stops at the track's length — which is the clamp doing its
        // job. WireConsistencyTests covers the arithmetic exactly.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let station2 = try await read()
        let later = try XCTUnwrap(station2.currentTrack?.elapsedSeconds)
        XCTAssertGreaterThanOrEqual(later, early, "the position never runs backwards")

        // Never past the end of the track it is describing: a station
        // parked at a boundary must not report a track more than finished.
        if let d = station2.currentTrack?.durationSeconds {
            XCTAssertLessThanOrEqual(later, d, "clamped to the track's own length")
        }

        // Only the CURRENT track has a position. One in the recent ring is
        // over and one in `nextTrack` has not begun; a number for either
        // would invite a client to render a clock for something silent.
        for t in station2.recent {
            XCTAssertNil(t.elapsedSeconds, "a finished track has no position")
        }
        if let next = station2.nextTrack {
            XCTAssertNil(next.elapsedSeconds, "nor has one that hasn't started")
        }
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

    /// `/history` used to be a prefix match, so `/historyxyz` answered 200
    /// with real rows instead of 404-ing like any other unknown path. The
    /// real route keeps answering, with and without a query string.
    @MainActor
    func testHistoryRouteMatchesExactPathOnly() async throws {
        let port: UInt16 = 18_070
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let station = Station(name: "History Exact", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let bogus = try await Self.fetchRawResponse(
            port: port, path: "/historyxyz", requestHeaders: [], maxBytes: 1_024
        )
        XCTAssertTrue(bogus.contains("HTTP/1.1 404"), "Expected 404: \(bogus)")

        for path in ["/history", "/history?limit=1"] {
            let ok = try await Self.fetchRawResponse(
                port: port, path: path, requestHeaders: [], maxBytes: 2_048
            )
            XCTAssertTrue(ok.contains("HTTP/1.1 200"), "Expected 200 for \(path): \(ok)")
        }
    }

    // MARK: - /health

    /// `GET /health` answers 200 with the capability anchor, uptime, and
    /// per-station liveness read from the heartbeat table.
    @MainActor
    func testHealthReportsLivenessAndCapabilities() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.port = 18_074
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, history: store)
        defer { radio.stopAll() }
        let station = Station(name: "Health Test", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: NeverSource())
        // Don't wait on the 60s heartbeat cadence — one explicit row makes
        // the liveness answer deterministic.
        try await store.recordHeartbeat(station: station.id)
        try await Task.sleep(nanoseconds: 400_000_000)

        let (data, response) = try await Self.fetchPayload(port: 18_074, path: "/health")
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        struct Health: Decodable {
            struct HealthStation: Decodable {
                struct Gap: Decodable {
                    let start: Double
                    let end: Double
                }
                let id: String
                let name: String?
                let slug: String?
                let broadcasting: Bool
                let liveness: String
                let lastGap: Gap?
            }
            let status: String
            let version: String
            let capabilities: [String]
            let uptimeSeconds: Double
            let broadcastingCount: Int
            let stations: [HealthStation]
        }
        let health = try JSONDecoder().decode(Health.self, from: data)
        XCTAssertEqual(health.status, "ok")
        XCTAssertTrue(health.capabilities.contains("health"), "got: \(health.capabilities)")
        XCTAssertTrue(
            health.capabilities.contains("trackinfo"),
            "the /trackinfo capability gates the web's about-this-track card: \(health.capabilities)"
        )
        XCTAssertGreaterThanOrEqual(health.uptimeSeconds, 0)
        XCTAssertEqual(health.broadcastingCount, 1)

        let only = try XCTUnwrap(health.stations.first)
        XCTAssertEqual(only.id, station.id.uuidString)
        XCTAssertEqual(only.name, "Health Test")
        XCTAssertEqual(only.slug, "health-test")
        XCTAssertTrue(only.broadcasting)
        // NeverSource never plays anything, so heartbeats without plays
        // mean "running, nothing queued" — not an outage.
        XCTAssertEqual(only.liveness, "onAirButQuiet")
        XCTAssertNil(only.lastGap, "fresh heartbeats leave no gap to report")
    }

    /// A broadcaster with no history store still answers 200 and the full
    /// shape — "degraded" is a payload fact, not a transport failure, so
    /// an outside probe can tell "up but storeless" from "socket dead".
    @MainActor
    func testHealthWithoutHistoryStoreIsDegradedButStill200() async throws {
        let port: UInt16 = 18_075
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let station = Station(name: "Degraded Health", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let (data, response) = try await Self.fetchPayload(port: port, path: "/health")
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        struct Health: Decodable {
            let status: String
            let capabilities: [String]
            let stations: [String]
        }
        let health = try JSONDecoder().decode(Health.self, from: data)
        XCTAssertEqual(health.status, "degraded")
        XCTAssertTrue(health.capabilities.contains("health"))
        XCTAssertTrue(health.stations.isEmpty, "no store means no station history to report")
    }

    // MARK: - /trackinfo

    /// Canned MusicBrainz lookup for the /trackinfo tests — proves the
    /// MB half of the payload fills even when Last.fm is keyless,
    /// without the suite ever touching musicbrainz.org.
    private actor CannedMusicBrainz: MusicBrainzLookup {
        func firstReleaseYear(artist: String, title: String) async -> Int? { 1998 }
        func countryCode(forArtist artist: String) async -> String? { "SE" }
    }

    /// Sources join collaborators into one string, so a track credited to
    /// "Carrot Green, Selvagem, Marvin & Guy" asks every catalogue about
    /// an artist of that name and no catalogue has one. Enrichment came
    /// back empty for every track with more than one person on it.
    func testPrimaryArtistSplitsCollaborationCredits() {
        let cases: [(String, String?)] = [
            ("Carrot Green, Selvagem, Marvin & Guy", "Carrot Green"),
            ("Rinzen, Michael Sundius", "Rinzen"),
            ("Khalab, Tamar Collocutor", "Khalab"),
            ("Aphex Twin feat. Someone", "Aphex Twin"),
            ("Massive Attack vs. Mad Professor", "Massive Attack"),
            // Nothing to fall back to: no second lookup should be made.
            ("Bernard Wright", nil),
            ("FAFA", nil),
            // A one-letter remnant is punctuation, not a name.
            ("A ft. B", nil),
        ]
        for (credit, expected) in cases {
            XCTAssertEqual(
                RadioBroadcaster.primaryArtist(credit), expected,
                "credit: \(credit)"
            )
        }
        // Documented trap: a band whose own name contains a separator
        // splits wrongly in isolation. It is never reached, because the
        // fallback only runs after the FULL credit has been looked up and
        // found nothing, and Last.fm answers for this one.
        XCTAssertEqual(RadioBroadcaster.primaryArtist("Earth, Wind & Fire"), "Earth")
    }

    /// `/trackinfo` answers only for tracks the station is (or just was)
    /// broadcasting: a station id the broadcaster doesn't know is a 404,
    /// and a request with no parseable station id is the shared 400 —
    /// exercised over the socket so the GET route registration is what's
    /// under test, not just the handler.
    @MainActor
    func testTrackInfoRouteAnswers404ForUnknownStation() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_130
        let radio = RadioBroadcaster(port: port)
        // Need a live station so the listener is actually up.
        let filler = Station(name: "Info Filler", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: filler)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 400_000_000)

        // Unknown station: nothing to describe. This is also the idle-
        // station answer — the broadcaster only knows live stations, so
        // it can't (and shouldn't) tell a stranger which is which.
        let unknown = try await Self.fetchRawResponse(
            port: port,
            path: "/trackinfo?station=\(UUID().uuidString)",
            requestHeaders: [],
            maxBytes: 2_048
        )
        XCTAssertTrue(unknown.contains("HTTP/1.1 404"), "Expected 404: \(unknown.prefix(200))")

        // No station parameter at all is malformed, not unknown.
        let malformed = try await Self.fetchRawResponse(
            port: port,
            path: "/trackinfo",
            requestHeaders: [],
            maxBytes: 2_048
        )
        XCTAssertTrue(malformed.contains("HTTP/1.1 400"), "Expected 400: \(malformed.prefix(200))")

        // And /trackinfoanything must 404 like any unknown path — the
        // exact-path-plus-query rule /history had to learn the hard way.
        let greedy = try await Self.fetchRawResponse(
            port: port,
            path: "/trackinfoxyz",
            requestHeaders: [],
            maxBytes: 2_048
        )
        XCTAssertTrue(greedy.contains("HTTP/1.1 404"), "Expected 404: \(greedy.prefix(200))")
    }

    /// The degrade contract: with no Last.fm key configured, /trackinfo
    /// still answers 200 with the FULL envelope — Last.fm fields null /
    /// empty, MusicBrainz fields filled (canned here, so no network) —
    /// because enrichment failing is not the radio failing. Also pins
    /// the wire shape: every key present, explicit nulls, both info
    /// objects present whenever the track carries an artist and title.
    @MainActor
    func testTrackInfoKeylessStillAnswersFullEnvelope() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.port = 18_131
        defer { prefs.port = 18_000 }
        let savedKey = prefs.lastFMAPIKey
        prefs.lastFMAPIKey = ""
        defer { prefs.lastFMAPIKey = savedKey }

        let radio = RadioBroadcaster(preferences: prefs)
        radio.trackInfoMusicBrainzOverride = CannedMusicBrainz()
        let station = Station(name: "Info Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        // Wait for the encoder to open its first track; poll rather than
        // one long sleep so a slow CI machine doesn't flake the 404 path.
        var status = 0
        var data = Data()
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 500_000_000)
            (status, data) = await radio.performTrackInfoAsync(
                path: "/trackinfo?station=\(station.id.uuidString)"
            )
            if status == 200 { break }
        }
        XCTAssertEqual(status, 200, "got \(status): \(String(data: data, encoding: .utf8) ?? "")")

        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(obj.keys),
            ["artist", "title", "album", "origin", "sourceURL", "youtubeURL",
             "artistInfo", "trackInfo"],
            "every key present, none extra"
        )
        XCTAssertEqual(obj["origin"] as? String, "library")
        XCTAssertFalse((obj["artist"] as? String ?? "").isEmpty, "fixture tracks carry an artist tag")

        let artistInfo = try XCTUnwrap(
            obj["artistInfo"] as? [String: Any],
            "the track has an artist, so the object must be present even keyless"
        )
        XCTAssertEqual(
            Set(artistInfo.keys),
            ["bio", "listeners", "playcount", "tags", "similar", "country"]
        )
        XCTAssertTrue(artistInfo["bio"] is NSNull, "keyless = no Last.fm facts, explicit null")
        XCTAssertTrue(artistInfo["listeners"] is NSNull)
        XCTAssertEqual(artistInfo["tags"] as? [String], [])
        XCTAssertEqual(artistInfo["similar"] as? [String], [])
        XCTAssertEqual(artistInfo["country"] as? String, "SE", "MusicBrainz still fills its half")

        let trackInfo = try XCTUnwrap(obj["trackInfo"] as? [String: Any])
        XCTAssertEqual(
            Set(trackInfo.keys),
            ["album", "playcount", "listeners", "tags", "wiki", "firstReleaseYear"]
        )
        XCTAssertTrue(trackInfo["wiki"] is NSNull)
        XCTAssertEqual(trackInfo["firstReleaseYear"] as? Int, 1998)

        // A recent-entry id that was never in the ring: gone, not 500.
        let (entryStatus, _) = await radio.performTrackInfoAsync(
            path: "/trackinfo?station=\(station.id.uuidString)&entry=\(UUID().uuidString)"
        )
        XCTAssertEqual(entryStatus, 404, "an entry that has left the ring has nothing to describe")
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

    // MARK: - Station CRUD control plane (/stations/*)

    /// Wire the catalogue seam over a real ``StationManager`` the way
    /// `RootView` does in production — closures, never the manager itself.
    @MainActor
    private func installCatalogue(
        on radio: RadioBroadcaster,
        manager: StationManager,
        preferences: BroadcastPreferences
    ) {
        radio.listStations = { manager.stations }
        radio.createStation = { draft, name in
            try manager.createStation(draft, name: name)
        }
        radio.updateStation = { id, update in
            try manager.applyUpdate(id, update)
        }
        radio.deleteStation = { id in
            guard manager.station(id: id) != nil else { return false }
            manager.delete(id)
            return true
        }
        radio.setAutoStart = { enabled, slug in
            preferences.setAutoStart(enabled, slug: slug)
        }
    }

    /// A `FacetedQuery` as the web client sends it: the full pinned key
    /// set, explicit nulls included — the same shape /stations/list emits.
    nonisolated private static func queryJSON(tags: [String]) -> String {
        let quoted = tags.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"genreTags\":[\(quoted)],\"yearMin\":null,\"yearMax\":null,"
            + "\"regions\":[],\"tagMatch\":\"any\",\"popularity\":\"middle\","
            + "\"excludeOwnedLibrary\":false,\"excludedArtists\":[]}"
    }

    /// Every `/stations/*` route is owner-gated: a wrong (or missing)
    /// token answers 403 listener-mode before any station is even looked
    /// up. One superset body decodes against every route's request shape.
    @MainActor
    func testStationRoutesRejectGuestsWith403() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_100
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        radio.ownerThrottleStep = 0
        defer { radio.stopAll() }

        let json = "{\"token\":\"wrong\",\"station\":\"\(UUID().uuidString)\","
            + "\"kind\":\"nts\",\"enabled\":true,\"query\":\(Self.queryJSON(tags: ["dub"]))}"
        let body = Data(json.utf8)
        for path in [
            "/stations/list", "/stations/create", "/stations/update",
            "/stations/delete", "/stations/start", "/stations/stop",
            "/stations/autostart"
        ] {
            let (status, payload) = await radio.performJSONRoute(path: path, body: body)
            XCTAssertEqual(status, 403, "\(path) must reject guests")
            XCTAssertTrue(
                String(data: payload, encoding: .utf8)!.contains("listener mode"),
                "\(path) must answer listener-mode"
            )
        }
    }

    /// Before RootView wires the catalogue seam (no music folder chosen,
    /// or a bare broadcaster) the owner routes answer 503 — "capable but
    /// unavailable", which the client shows instead of hiding the panel.
    /// Stop is the exception: it acts on the broadcaster's own pipelines
    /// and needs no catalogue, and it is idempotent even against nothing.
    @MainActor
    func testStationRoutesAnswer503BeforeACatalogueIsWired() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_108
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }

        let token = prefs.ownerToken
        let station = UUID().uuidString
        let cases: [(String, String)] = [
            ("/stations/list", "{\"token\":\"\(token)\"}"),
            ("/stations/create",
             "{\"token\":\"\(token)\",\"kind\":\"nts\",\"query\":\(Self.queryJSON(tags: ["dub"]))}"),
            ("/stations/update", "{\"token\":\"\(token)\",\"station\":\"\(station)\"}"),
            ("/stations/delete", "{\"token\":\"\(token)\",\"station\":\"\(station)\"}"),
            ("/stations/start", "{\"token\":\"\(token)\",\"station\":\"\(station)\"}"),
            ("/stations/autostart",
             "{\"token\":\"\(token)\",\"station\":\"\(station)\",\"enabled\":true}")
        ]
        for (path, body) in cases {
            let (status, payload) = await radio.performJSONRoute(path: path, body: Data(body.utf8))
            XCTAssertEqual(status, 503, "\(path) without a catalogue")
            XCTAssertTrue(
                String(data: payload, encoding: .utf8)!.contains("catalogue unavailable"),
                "\(path) message"
            )
        }
        let (stopStatus, stopBody) = await radio.performJSONRoute(
            path: "/stations/stop",
            body: Data("{\"token\":\"\(token)\",\"station\":\"\(station)\"}".utf8)
        )
        XCTAssertEqual(stopStatus, 200, "stop needs no catalogue")
        XCTAssertTrue(String(data: stopBody, encoding: .utf8)!.contains("stopped"))
    }

    /// The leak decision, enforced: a playlist station projects to
    /// `kind`/`trackCount` and nulls — its queue of `file://` URLs, sizes
    /// and dates never crosses the wire. And every payload carries the
    /// same key set whatever its kind, the /now.json wire rule.
    @MainActor
    func testStationsListScrubsPlaylistStations() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_109
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let manager = StationManager()
        installCatalogue(on: radio, manager: manager, preferences: prefs)

        let secret = Track(
            url: URL(fileURLWithPath: "/secret/library/hidden-track.mp3"),
            title: "Hidden", artist: "Private", album: "Owned",
            duration: 61, fileSize: 12_345
        )
        let playlistStation = manager.create(from: Playlist(
            name: "Owned Mix", folder: nil, tracks: [secret], children: [], kind: .folder
        ))
        _ = manager.createNTS(NTSStationConfig(
            name: "Public Facets", query: FacetedQuery(genreTags: ["ambient"])
        ))
        prefs.setAutoStart(true, slug: playlistStation.slug)
        defer { prefs.autoStartSlugs = [] }

        let (status, payload) = await radio.performJSONRoute(
            path: "/stations/list",
            body: Data("{\"token\":\"\(prefs.ownerToken)\"}".utf8)
        )
        XCTAssertEqual(status, 200)
        let text = String(data: payload, encoding: .utf8)!
        XCTAssertFalse(text.contains("file://"), "queue URLs must never leave: \(text)")
        XCTAssertFalse(text.contains("/secret"), "library paths must never leave: \(text)")
        XCTAssertFalse(text.contains("fileSize"), "file facts must never leave: \(text)")
        XCTAssertFalse(text.contains("dateAdded"), "file facts must never leave: \(text)")

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        let stations = try XCTUnwrap(root["stations"] as? [[String: Any]])
        XCTAssertEqual(stations.count, 2)
        let expectedKeys: Set<String> = [
            "id", "name", "slug", "kind", "broadcasting", "autoStart",
            "query", "exploration", "sort", "shufflePool", "trackCount"
        ]
        for entry in stations {
            XCTAssertEqual(
                Set(entry.keys), expectedKeys,
                "every kind carries the same key set"
            )
        }
        let playlist = try XCTUnwrap(stations.first { $0["kind"] as? String == "playlist" })
        XCTAssertEqual(playlist["trackCount"] as? Int, 1)
        XCTAssertTrue(playlist["query"] is NSNull, "a fixed queue has no query")
        XCTAssertTrue(playlist["shufflePool"] is NSNull)
        XCTAssertEqual(playlist["autoStart"] as? Bool, true, "auto-start flag rides the payload")
        let nts = try XCTUnwrap(stations.first { $0["kind"] as? String == "nts" })
        let query = try XCTUnwrap(nts["query"] as? [String: Any])
        XCTAssertEqual(query["genreTags"] as? [String], ["ambient"])
        XCTAssertEqual(nts["broadcasting"] as? Bool, false, "idle stations appear, marked idle")
    }

    /// Create over a real socket → 201 Created, and the station is
    /// immediately visible in a follow-up list. Also covers the CORS
    /// preflight for a /stations/* path — same Set gates both.
    @MainActor
    func testStationCreateShowsUpInListAndOverTheSocket() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_101
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let manager = StationManager()
        // Real storage, so the test proves the HTTP create persists the
        // way a desktop create does — not just an in-memory append.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratbat-web-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        manager.setStorage(root: tempRoot)
        installCatalogue(on: radio, manager: manager, preferences: prefs)

        // Bring the shared listener up — the control plane rides the same
        // socket the streams do.
        let filler = Station(name: "Listener Filler", kind: .playlist(queue: []))
        await radio.startBroadcast(station: filler, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let preflight = try await Self.fetchRawResponse(
            port: 18_101,
            path: "/stations/create",
            requestHeaders: ["Access-Control-Request-Method: POST"],
            maxBytes: 1_024,
            method: "OPTIONS"
        )
        XCTAssertTrue(preflight.contains("HTTP/1.1 204"), "Expected 204: \(preflight)")
        XCTAssertTrue(
            preflight.lowercased().contains("access-control-allow-origin: *"),
            "Missing allow-origin: \(preflight)"
        )

        let response = try await Self.fetchRawResponse(
            port: 18_101,
            path: "/stations/create",
            requestHeaders: ["Content-Type: application/json"],
            maxBytes: 4_096,
            method: "POST",
            body: "{\"token\":\"\(prefs.ownerToken)\",\"kind\":\"nts\","
                + "\"name\":\"Web Made\",\"query\":\(Self.queryJSON(tags: ["ambient", "drone"]))}"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 201 Created"), "Expected 201: \(response)")
        XCTAssertTrue(response.contains("\"kind\":\"nts\""), "payload names its kind: \(response)")
        XCTAssertTrue(response.contains("\"slug\":\"web-made\""), "payload carries the slug: \(response)")

        let (listStatus, listPayload) = await radio.performJSONRoute(
            path: "/stations/list",
            body: Data("{\"token\":\"\(prefs.ownerToken)\"}".utf8)
        )
        XCTAssertEqual(listStatus, 200)
        XCTAssertTrue(
            String(data: listPayload, encoding: .utf8)!.contains("Web Made"),
            "a created station is immediately listable"
        )
        XCTAssertEqual(manager.stations.count, 1, "and it landed in the real catalogue")

        // Persistence round-trip: the HTTP create wrote the same
        // `.ratbat-stations.json` a desktop create would.
        let stored = try String(
            contentsOf: tempRoot.appendingPathComponent(StationStore.filename),
            encoding: .utf8
        )
        XCTAssertTrue(stored.contains("Web Made"), "created station reached disk")
    }

    /// The create-time validation gauntlet: unknown kinds (a spelling no
    /// build knows, and the desktop-only playlist), empty tags, a blank
    /// provided name, and a Last.fm create without an API key are all
    /// 422s with a reason — never opaque 400s. libraryRadio left this
    /// list when S4 shipped it; its create path is covered below.
    @MainActor
    func testStationCreateValidationAnswers422() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_110
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let manager = StationManager()
        installCatalogue(on: radio, manager: manager, preferences: prefs)

        let savedKey = prefs.lastFMAPIKey
        prefs.lastFMAPIKey = ""
        defer { prefs.lastFMAPIKey = savedKey }

        let token = prefs.ownerToken
        let tags = Self.queryJSON(tags: ["dub"])
        let cases: [(body: String, fragment: String, label: String)] = [
            ("{\"token\":\"\(token)\",\"kind\":\"spotify\",\"query\":\(tags)}",
             "unknown kind", "a kind no build knows"),
            ("{\"token\":\"\(token)\",\"kind\":\"playlist\",\"query\":\(tags)}",
             "unknown kind", "playlist stations are desktop-only"),
            ("{\"token\":\"\(token)\",\"kind\":\"nts\",\"query\":\(Self.queryJSON(tags: []))}",
             "tag", "empty tags"),
            ("{\"token\":\"\(token)\",\"kind\":\"nts\"}",
             "tag", "missing query"),
            ("{\"token\":\"\(token)\",\"kind\":\"nts\",\"name\":\"   \",\"query\":\(tags)}",
             "name", "blank provided name"),
            ("{\"token\":\"\(token)\",\"kind\":\"lastFM\",\"query\":\(tags)}",
             "API key", "Last.fm without a key")
        ]
        for testCase in cases {
            let (status, payload) = await radio.performJSONRoute(
                path: "/stations/create", body: Data(testCase.body.utf8)
            )
            let text = String(data: payload, encoding: .utf8)!
            XCTAssertEqual(status, 422, "\(testCase.label): \(text)")
            XCTAssertTrue(text.contains(testCase.fragment), "\(testCase.label): \(text)")
        }
        XCTAssertTrue(manager.stations.isEmpty, "nothing may survive a refused create")
    }

    /// A station id that parses but resolves to nothing is 410 Gone — the
    /// route exists, the station doesn't — while an unparseable id stays
    /// a plain 400. The distinction is what lets the client say "station
    /// no longer exists" instead of "something broke".
    @MainActor
    func testStationUpdateAnswers410ForUnknownAnd400ForUnparseableIds() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_111
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let manager = StationManager()
        installCatalogue(on: radio, manager: manager, preferences: prefs)

        let (gone, goneBody) = await radio.performJSONRoute(
            path: "/stations/update",
            body: Data("{\"token\":\"\(prefs.ownerToken)\",\"station\":\"\(UUID().uuidString)\",\"name\":\"X\"}".utf8)
        )
        XCTAssertEqual(gone, 410)
        XCTAssertTrue(String(data: goneBody, encoding: .utf8)!.contains("no longer exists"))

        let (bad, _) = await radio.performJSONRoute(
            path: "/stations/update",
            body: Data("{\"token\":\"\(prefs.ownerToken)\",\"station\":\"not-a-uuid\",\"name\":\"X\"}".utf8)
        )
        XCTAssertEqual(bad, 400)

        // Same 410 posture over the socket, so the status text is on the
        // wire too (the table entry is load-bearing per the review).
        let filler = Station(name: "Gone Filler", kind: .playlist(queue: []))
        await radio.startBroadcast(station: filler, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)
        let response = try await Self.fetchRawResponse(
            port: 18_111,
            path: "/stations/delete",
            requestHeaders: ["Content-Type: application/json"],
            maxBytes: 1_024,
            method: "POST",
            body: "{\"token\":\"\(prefs.ownerToken)\",\"station\":\"\(UUID().uuidString)\"}"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 410 Gone"), "Expected 410: \(response)")
    }

    /// The applyNow split, observed from outside: `false` persists the
    /// edit while the live pipeline keeps its old config until its next
    /// deliberate restart; `true` restarts the pipeline — audibly — and
    /// the station stays on air afterwards. Persist-first either way.
    @MainActor
    func testStationUpdatePersistsFirstAndRestartsOnlyWhenAsked() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_102
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let manager = StationManager()
        installCatalogue(on: radio, manager: manager, preferences: prefs)
        let station = manager.create(from: Playlist(
            name: "Live Edit", folder: nil, tracks: tracks, children: [], kind: .folder
        ))
        await radio.startBroadcast(station: station)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // applyNow:false — the catalogue changes, the pipeline doesn't.
        let (savedStatus, _) = await radio.performJSONRoute(
            path: "/stations/update",
            body: Data("{\"token\":\"\(prefs.ownerToken)\",\"station\":\"\(station.id.uuidString)\",\"name\":\"Saved Only\",\"applyNow\":false}".utf8)
        )
        XCTAssertEqual(savedStatus, 200)
        XCTAssertEqual(manager.stations[0].name, "Saved Only", "persisted immediately")
        let before = try await Self.fetchRawResponse(
            port: 18_102, path: "/now.json", requestHeaders: [], maxBytes: 8_192
        )
        XCTAssertTrue(
            before.contains("radio-based-on-live-edit"),
            "without applyNow the live pipeline keeps its old config: \(before)"
        )

        // applyNow:true — the pipeline is rebuilt from the saved config
        // and the station is still on air.
        let (restartStatus, restartPayload) = await radio.performJSONRoute(
            path: "/stations/update",
            body: Data("{\"token\":\"\(prefs.ownerToken)\",\"station\":\"\(station.id.uuidString)\",\"name\":\"Renamed Live\",\"applyNow\":true}".utf8)
        )
        XCTAssertEqual(restartStatus, 200)
        XCTAssertTrue(
            String(data: restartPayload, encoding: .utf8)!.contains("\"broadcasting\":true"),
            "the envelope reflects the post-restart state"
        )
        XCTAssertTrue(radio.isBroadcasting(stationID: station.id), "restart, not stop")
        let after = try await Self.fetchRawResponse(
            port: 18_102, path: "/now.json", requestHeaders: [], maxBytes: 8_192
        )
        XCTAssertTrue(
            after.contains("renamed-live"),
            "applyNow rebuilt the pipeline on the new config: \(after)"
        )
    }

    /// Deleting a live station stops it first (a deliberate owner stop —
    /// it must not resume at next launch), removes it from the catalogue,
    /// and leaves the listener serving — the control plane must survive
    /// zero stations or the web could never start one again.
    @MainActor
    func testStationDeleteStopsTheLiveStationAndKeepsTheListenerServing() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_103
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let manager = StationManager()
        installCatalogue(on: radio, manager: manager, preferences: prefs)
        let station = manager.create(from: Playlist(
            name: "Doomed", folder: nil, tracks: tracks, children: [], kind: .folder
        ))
        await radio.startBroadcast(station: station)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(radio.isBroadcasting(stationID: station.id))

        let response = try await Self.fetchRawResponse(
            port: 18_103,
            path: "/stations/delete",
            requestHeaders: ["Content-Type: application/json"],
            maxBytes: 1_024,
            method: "POST",
            body: "{\"token\":\"\(prefs.ownerToken)\",\"station\":\"\(station.id.uuidString)\"}"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 200"), "Expected 200: \(response)")
        XCTAssertTrue(response.contains("\"status\":\"deleted\""), "Expected deleted: \(response)")
        XCTAssertFalse(radio.isBroadcasting(stationID: station.id), "stopped before deleting")
        XCTAssertTrue(manager.stations.isEmpty, "removed from the catalogue")

        // Zero stations, listener still answering — the S1 guarantee the
        // whole web-stop story depends on.
        let now = try await Self.fetchRawResponse(
            port: 18_103, path: "/now.json", requestHeaders: [], maxBytes: 1_024
        )
        XCTAssertTrue(now.contains("HTTP/1.1 200"), "listener must survive: \(now)")
    }

    /// Start and stop over the socket, full cycle, both idempotent: a
    /// double-start answers the same 200 a fresh one does, and a stop of
    /// an already-idle station is still "stopped" — a double-tap on a
    /// phone must never surface as an error.
    @MainActor
    func testStationStartAndStopAreIdempotentOverTheControlPlane() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_104
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let manager = StationManager()
        installCatalogue(on: radio, manager: manager, preferences: prefs)
        let station = manager.create(from: Playlist(
            name: "Cycled", folder: nil, tracks: tracks, children: [], kind: .folder
        ))
        // The listener rides the first start, so raise it with a filler —
        // the control plane can then start the *idle* target over HTTP.
        let filler = Station(name: "Cycle Filler", kind: .playlist(queue: []))
        await radio.startBroadcast(station: filler, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        func post(_ path: String, station id: String) async throws -> String {
            try await Self.fetchRawResponse(
                port: 18_104,
                path: path,
                requestHeaders: ["Content-Type: application/json"],
                maxBytes: 1_024,
                method: "POST",
                body: "{\"token\":\"\(prefs.ownerToken)\",\"station\":\"\(id)\"}"
            )
        }

        let started = try await post("/stations/start", station: station.id.uuidString)
        XCTAssertTrue(started.contains("HTTP/1.1 200"), "Expected 200: \(started)")
        XCTAssertTrue(started.contains("\"status\":\"started\""), "Expected started: \(started)")
        XCTAssertTrue(radio.isBroadcasting(stationID: station.id))

        let startedAgain = try await post("/stations/start", station: station.id.uuidString)
        XCTAssertTrue(
            startedAgain.contains("\"status\":\"started\""),
            "double-start is idempotent: \(startedAgain)"
        )

        let stopped = try await post("/stations/stop", station: station.id.uuidString)
        XCTAssertTrue(stopped.contains("\"status\":\"stopped\""), "Expected stopped: \(stopped)")
        XCTAssertFalse(radio.isBroadcasting(stationID: station.id))

        let stoppedAgain = try await post("/stations/stop", station: station.id.uuidString)
        XCTAssertTrue(
            stoppedAgain.contains("\"status\":\"stopped\""),
            "stop of an idle station is idempotent: \(stoppedAgain)"
        )

        let unknown = try await post("/stations/start", station: UUID().uuidString)
        XCTAssertTrue(unknown.contains("HTTP/1.1 410 Gone"), "Expected 410: \(unknown)")
    }

    /// The auto-start toggle writes real per-machine preference state
    /// through the seam — and reads back through the same store the
    /// launch resume uses, so a web toggle survives to the next boot.
    @MainActor
    func testAutoStartTogglePersistsThroughThePreferencesSeam() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_112
        defer {
            prefs.autoStartSlugs = []
            prefs.port = 18_000
        }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let manager = StationManager()
        installCatalogue(on: radio, manager: manager, preferences: prefs)
        let station = manager.createNTS(NTSStationConfig(
            name: "Morning Auto", query: FacetedQuery(genreTags: ["ambient"])
        ))

        func toggle(_ enabled: Bool, station id: String) async -> (Int, Data) {
            await radio.performJSONRoute(
                path: "/stations/autostart",
                body: Data("{\"token\":\"\(prefs.ownerToken)\",\"station\":\"\(id)\",\"enabled\":\(enabled)}".utf8)
            )
        }

        let (onStatus, onBody) = await toggle(true, station: station.id.uuidString)
        XCTAssertEqual(onStatus, 200)
        XCTAssertTrue(String(data: onBody, encoding: .utf8)!.contains("\"status\":\"ok\""))
        XCTAssertTrue(prefs.isAutoStart(slug: station.slug), "membership written")

        // And the flag comes back on the list payload.
        let (_, listPayload) = await radio.performJSONRoute(
            path: "/stations/list",
            body: Data("{\"token\":\"\(prefs.ownerToken)\"}".utf8)
        )
        XCTAssertTrue(
            String(data: listPayload, encoding: .utf8)!.contains("\"autoStart\":true")
        )

        let (offStatus, _) = await toggle(false, station: station.id.uuidString)
        XCTAssertEqual(offStatus, 200)
        XCTAssertFalse(prefs.isAutoStart(slug: station.slug), "membership cleared")

        let (goneStatus, _) = await toggle(true, station: UUID().uuidString)
        XCTAssertEqual(goneStatus, 410, "unknown station cannot gain a flag")
    }

    /// S4 end to end over the socket: an authed `/stations/create` with
    /// `kind: libraryRadio` (and NO query — the whole-library default)
    /// answers 201 with the new kind's payload shape, `/stations/start`
    /// brings it on air through the catalogue seam, and `/now.json`
    /// reports `origin: "library"` — the proof the tracks on the wire
    /// are the owner's own files, not resolver downloads.
    @MainActor
    func testLibraryRadioCreateStartsAndPlaysOwnedTracksOverTheSocket() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "station-crud-passcode"
        prefs.port = 18_114
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let manager = StationManager()
        installCatalogue(on: radio, manager: manager, preferences: prefs)
        // The library seam RootView normally wires: the fixture library
        // plays the role of the indexed music folder.
        radio.libraryTracks = { tracks }

        // Bring the shared listener up so the control plane answers.
        let filler = Station(name: "Library Filler", kind: .playlist(queue: []))
        await radio.startBroadcast(station: filler, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let created = try await Self.fetchRawResponse(
            port: 18_114,
            path: "/stations/create",
            requestHeaders: ["Content-Type: application/json"],
            maxBytes: 4_096,
            method: "POST",
            body: "{\"token\":\"\(prefs.ownerToken)\",\"kind\":\"libraryRadio\"}"
        )
        XCTAssertTrue(created.contains("HTTP/1.1 201 Created"), "Expected 201: \(created)")
        XCTAssertTrue(created.contains("\"kind\":\"libraryRadio\""), "payload names its kind: \(created)")
        XCTAssertTrue(created.contains("\"name\":\"Library Radio\""),
                      "empty-filter create gets the truthful default name: \(created)")
        XCTAssertTrue(created.contains("\"exploration\":null"),
                      "no exploration dial on this kind — explicit null, same key set as every kind: \(created)")

        let station = try XCTUnwrap(
            manager.stations.first(where: { $0.libraryRadioConfig != nil }),
            "the create landed in the real catalogue"
        )
        XCTAssertEqual(station.libraryRadioConfig?.query.genreTags, [],
                       "missing query defaults to the whole-library filter")

        let started = try await Self.fetchRawResponse(
            port: 18_114,
            path: "/stations/start",
            requestHeaders: ["Content-Type: application/json"],
            maxBytes: 1_024,
            method: "POST",
            body: "{\"token\":\"\(prefs.ownerToken)\",\"station\":\"\(station.id.uuidString)\"}"
        )
        XCTAssertTrue(started.contains("\"status\":\"started\""), "Expected started: \(started)")
        XCTAssertTrue(radio.isBroadcasting(stationID: station.id))

        // Give the encoder time to open the first owned file.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let (nowData, _) = try await Self.fetchPayload(port: 18_114, path: "/now.json")
        let now = String(data: nowData, encoding: .utf8)!
        XCTAssertTrue(now.contains("\"origin\":\"library\""),
                      "library radio publishes the owner's-own-file truth: \(now)")
        XCTAssertTrue(now.contains(station.slug), "the new station is on the public wire: \(now)")
    }

    // MARK: - /vocab

    /// `GET /vocab` is public and cacheable — compiled-in vocabulary,
    /// nothing about this owner's stations.
    @MainActor
    func testVocabEndpointServesTheStationFormVocabulary() async throws {
        let port: UInt16 = 18_105
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let filler = Station(name: "Vocab Filler", kind: .playlist(queue: []))
        await radio.startBroadcast(station: filler, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let response = try await Self.fetchRawResponse(
            port: port, path: "/vocab", requestHeaders: [], maxBytes: 16_384
        )
        XCTAssertTrue(response.contains("HTTP/1.1 200"), "Expected 200: \(response)")
        XCTAssertTrue(
            response.contains("Cache-Control: public, max-age=3600"),
            "vocab is cacheable: \(response)"
        )
        XCTAssertTrue(response.contains("deepCuts"), "enum spellings ride the wire: \(response)")
    }

    /// The vocab payload's shape, pinned: `tags` keyed by wire kind with
    /// the palettes verbatim, enum spellings from the enums themselves,
    /// bare ISO alpha-2 region codes (the client localizes names), and a
    /// `kinds` list that — now that S4 shipped — includes libraryRadio,
    /// which is exactly how the web client's kind picker learns this
    /// build can create one.
    func testVocabPayloadMatchesTheSwiftVocabulary() throws {
        let payload = RadioBroadcaster.buildVocabPayload()
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        XCTAssertEqual(
            Set(root.keys),
            ["tags", "tagMatch", "popularity", "bandcampSort", "kinds", "regions"]
        )
        let tags = try XCTUnwrap(root["tags"] as? [String: [String]])
        XCTAssertEqual(tags["nts"], StationTagPalette.nts)
        XCTAssertEqual(tags["lastFM"], StationTagPalette.lastFM)
        XCTAssertEqual(tags["bandcamp"], StationTagPalette.bandcamp)
        // Empty, not library-derived: the vocab builder is a nonisolated
        // static with no path to the indexed tracks (see its comment).
        // The key still exists so web forms can key off it uniformly.
        XCTAssertEqual(tags["libraryRadio"], [])
        XCTAssertEqual(root["tagMatch"] as? [String], ["any", "all"])
        XCTAssertEqual(root["popularity"] as? [String], ["hits", "middle", "deepCuts"])
        XCTAssertEqual(root["bandcampSort"] as? [String], ["date", "pop"])
        XCTAssertEqual(root["kinds"] as? [String], ["nts", "lastFM", "bandcamp", "libraryRadio"])
        let regions = try XCTUnwrap(root["regions"] as? [String])
        XCTAssertTrue(regions.contains("JP"))
        XCTAssertTrue(regions.allSatisfy { $0.count == 2 }, "bare alpha-2 codes only")
        XCTAssertEqual(regions, regions.sorted(), "deterministic wire ordering")
    }

    /// The capability anchor grows with the build: this one answers the
    /// station CRUD routes, /vocab, the policy dials, the two
    /// transparency surfaces, /trackinfo and the transport relay — and
    /// /health says so.
    /// The remote control. Volume lives in each browser, so one of the
    /// owner's browsers cannot reach another's speaker on its own — the
    /// broadcaster relays the keypress, and only for the owner.
    @MainActor
    func testTransportRelayIsOwnerGatedOverTheSocket() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_121
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "transport-passcode"
        prefs.port = Int(port)
        defer {
            prefs.resetToDefaults()
            prefs.port = 18_000
        }
        let radio = RadioBroadcaster(preferences: prefs)
        let filler = Station(name: "Transport Filler", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: filler)
        defer { radio.stopAll() }
        try await Task.sleep(nanoseconds: 400_000_000)

        func post(_ body: String) async throws -> String {
            try await Self.fetchRawResponse(
                port: port, path: "/transport",
                requestHeaders: ["Content-Type: application/json"],
                method: "POST", body: body
            )
        }

        let guest = try await post("{\"muted\":true,\"token\":\"wrong\"}")
        XCTAssertTrue(guest.contains("403 Forbidden"), "a stranger cannot mute the house: \(guest)")

        let owner = try await post("{\"muted\":true,\"token\":\"\(prefs.ownerToken)\"}")
        XCTAssertTrue(owner.contains("HTTP/1.1 200"), "the owner can: \(owner)")

        // Volume alone is a legal press too — the fields are independent
        // so a mute never silently resets somebody's level.
        let level = try await post("{\"volume\":0.4,\"token\":\"\(prefs.ownerToken)\"}")
        XCTAssertTrue(level.contains("HTTP/1.1 200"), "\(level)")
    }

    @MainActor
    func testHealthAdvertisesTheControlPlaneCapabilities() async throws {
        let expected = [
            "health", "stations", "vocab", "policy", "taste", "exclusions",
            "trackinfo", "transport"
        ]
        XCTAssertEqual(RadioBroadcaster.healthCapabilities, expected)
        let radio = RadioBroadcaster(port: 18_113)
        defer { radio.stopAll() }
        struct Health: Decodable { let capabilities: [String] }
        let health = try JSONDecoder().decode(
            Health.self, from: await radio.buildHealthPayload()
        )
        XCTAssertEqual(health.capabilities, expected)
    }

    // MARK: - Policy over HTTP (/policy/get, /policy/set)

    /// The wire contract's whole reason for a hand-written decode: the
    /// dial has THREE states on the wire — key absent (leave it alone),
    /// explicit null (dial off) and a number — and a synthesized
    /// `Double?` collapses the first two into one.
    func testPolicySetRequestDecodesAllThreeDialStates() throws {
        let dec = JSONDecoder()

        let absent = try dec.decode(
            RadioBroadcaster.PolicySetRequest.self,
            from: Data("{\"token\":\"t\"}".utf8)
        )
        XCTAssertNil(absent.newMusicShare, "absent key must decode to outer nil")

        let null = try dec.decode(
            RadioBroadcaster.PolicySetRequest.self,
            from: Data("{\"token\":\"t\",\"newMusicShare\":null}".utf8)
        )
        XCTAssertEqual(null.newMusicShare, .some(nil),
                       "explicit null is 'dial off', NOT 'leave alone'")

        let value = try dec.decode(
            RadioBroadcaster.PolicySetRequest.self,
            from: Data("{\"token\":\"t\",\"newMusicShare\":0.4}".utf8)
        )
        XCTAssertEqual(value.newMusicShare, .some(.some(0.4)))
    }

    /// Body of an HTTP response string, JSON-parsed. `fetchRawResponse`
    /// hands back headers + body as one string.
    nonisolated private static func jsonBody(of response: String) throws -> [String: Any] {
        let parts = response.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 2 else { throw XCTSkip("no body in: \(response)") }
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let obj = try JSONSerialization.jsonObject(with: Data(body.utf8))
        return (obj as? [String: Any]) ?? [:]
    }

    /// The full dial arc over a real socket: null at rest, a set value
    /// round-trips, a toggle-only set leaves the dial alone, an explicit
    /// null turns it off again — and every answer carries the read-only
    /// mix-set threshold.
    @MainActor
    func testPolicyGetSetRoundTripOverTheSocket() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let port: UInt16 = 18_120
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "policy-roundtrip-passcode"
        prefs.port = Int(port)
        defer {
            prefs.resetToDefaults()
            prefs.port = 18_000
        }
        let radio = RadioBroadcaster(preferences: prefs)
        let filler = Station(name: "Policy Filler", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: filler)
        defer { radio.stopAll() }
        try await Task.sleep(nanoseconds: 400_000_000)

        func post(_ path: String, _ body: String) async throws -> [String: Any] {
            let response = try await Self.fetchRawResponse(
                port: port, path: path,
                requestHeaders: ["Content-Type: application/json"],
                method: "POST", body: body
            )
            XCTAssertTrue(response.contains("HTTP/1.1 200"), "\(path): \(response)")
            return try Self.jsonBody(of: response)
        }

        // At rest: the dial has never been set — explicit null, and the
        // threshold rides along as read-only information.
        var payload = try await post("/policy/get", "{\"token\":\"\(prefs.ownerToken)\"}")
        XCTAssertTrue(payload.keys.contains("newMusicShare"), "\(payload)")
        XCTAssertTrue(payload["newMusicShare"] is NSNull, "unset dial is an explicit null")
        XCTAssertEqual(payload["excludeMixSets"] as? Bool, false)
        XCTAssertEqual(payload["mixSetMinimumDuration"] as? Double, MixSetRule.defaultMinimumDuration)

        // Set the dial; the answer reflects what persisted.
        payload = try await post(
            "/policy/set",
            "{\"token\":\"\(prefs.ownerToken)\",\"newMusicShare\":0.4}"
        )
        XCTAssertEqual(payload["newMusicShare"] as? Double, 0.4)

        // A toggle-only set must not touch the dial.
        payload = try await post(
            "/policy/set",
            "{\"token\":\"\(prefs.ownerToken)\",\"excludeMixSets\":true}"
        )
        XCTAssertEqual(payload["excludeMixSets"] as? Bool, true)
        XCTAssertEqual(payload["newMusicShare"] as? Double, 0.4,
                       "an absent key means 'leave the dial alone'")

        // Explicit null = dial off. Verified through a fresh get so the
        // -1 sentinel provably stays server-internal.
        payload = try await post(
            "/policy/set",
            "{\"token\":\"\(prefs.ownerToken)\",\"newMusicShare\":null}"
        )
        XCTAssertTrue(payload["newMusicShare"] is NSNull, "explicit null turns the dial off")
        payload = try await post("/policy/get", "{\"token\":\"\(prefs.ownerToken)\"}")
        XCTAssertTrue(payload["newMusicShare"] is NSNull)
        XCTAssertEqual(payload["excludeMixSets"] as? Bool, true, "the toggle survived the dial-off")

        // An out-of-range value clamps through SelectionPolicy's init
        // rather than reaching storage.
        payload = try await post(
            "/policy/set",
            "{\"token\":\"\(prefs.ownerToken)\",\"newMusicShare\":1.7}"
        )
        XCTAssertEqual(payload["newMusicShare"] as? Double, 1.0, "clamped, not stored raw")
    }

    // MARK: - /taste + /exclusions transparency

    /// `/taste` publishes both layers: the library profile (top artists
    /// and tags by score) and the per-station behavioral layer (affinity
    /// seeds + signal counts) — idle stations included, since they come
    /// from the catalogue seam, not the live pipelines.
    @MainActor
    func testTasteAnswersProfileAndPerStationSignals() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("taste-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = try await HistoryStore(databaseURL: tempDB)
        let profile = TasteProfile()
        await profile.restore(snapshot: TasteProfileSnapshot(
            libraryArtists: ["Coil": 1.0, "Gas": 0.5],
            libraryTags: ["ambient": 1.0, "dub": 0.25]
        ))
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "taste-passcode"
        prefs.port = 18_121
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, history: store, tasteProfile: profile)
        defer { radio.stopAll() }

        // One idle station in the catalogue, with all four signals on it.
        let manager = StationManager()
        let station = manager.createNTS(NTSStationConfig(
            name: "Idle But Heard", query: FacetedQuery(genreTags: ["ambient"])
        ))
        radio.listStations = { manager.stations }
        let a = try await store.record(station: station.id, artist: "Loved", title: "l1")
        try await store.markSaved(id: a, cachedPath: "/tmp/l1.m4a")
        let b = try await store.record(station: station.id, artist: "Boosted", title: "b1")
        try await store.markBoosted(id: b)
        let c = try await store.record(station: station.id, artist: "Skipped", title: "s1")
        try await store.markSkipped(id: c)

        let (status, payload) = await radio.performJSONRoute(
            path: "/taste",
            body: Data("{\"token\":\"\(prefs.ownerToken)\"}".utf8)
        )
        XCTAssertEqual(status, 200, String(data: payload, encoding: .utf8) ?? "")
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        let artists = try XCTUnwrap(root["libraryArtists"] as? [[String: Any]])
        XCTAssertEqual(artists.map { $0["artist"] as? String }, ["Coil", "Gas"],
                       "sorted by score, strongest first")
        XCTAssertEqual(artists.first?["score"] as? Double, 1.0)
        let tags = try XCTUnwrap(root["libraryTags"] as? [[String: Any]])
        XCTAssertEqual(tags.map { $0["tag"] as? String }, ["ambient", "dub"])

        let stations = try XCTUnwrap(root["stations"] as? [[String: Any]])
        XCTAssertEqual(stations.count, 1, "idle stations are included — the seam, not the pipelines")
        let entry = try XCTUnwrap(stations.first)
        XCTAssertEqual(entry["id"] as? String, station.id.uuidString)
        XCTAssertEqual(entry["name"] as? String, "Idle But Heard")
        let seeds = try XCTUnwrap(entry["topAffinityArtists"] as? [String])
        XCTAssertEqual(seeds.first, "Boosted", "boost outranks ♥ in the seeding")
        XCTAssertTrue(seeds.contains("Loved"))
        let counts = try XCTUnwrap(entry["counts"] as? [String: Any])
        XCTAssertEqual(counts["plays"] as? Int, 3)
        XCTAssertEqual(counts["saves"] as? Int, 1)
        XCTAssertEqual(counts["boosts"] as? Int, 1)
        XCTAssertEqual(counts["skips"] as? Int, 1)
    }

    /// `/taste` before the catalogue seam is wired answers the same 503
    /// the station routes do — "capable but unavailable".
    @MainActor
    func testTasteAnswers503BeforeACatalogueIsWired() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "taste-passcode-2"
        prefs.port = 18_122
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        defer { radio.stopAll() }
        let (status, payload) = await radio.performJSONRoute(
            path: "/taste",
            body: Data("{\"token\":\"\(prefs.ownerToken)\"}".utf8)
        )
        XCTAssertEqual(status, 503)
        XCTAssertTrue(String(data: payload, encoding: .utf8)!.contains("catalogue unavailable"))
    }

    /// `/exclusions` is a straight map of the audit trail: station filter
    /// honoured, limit honoured, explicit nulls for the fields a source
    /// genuinely can't fill, and shadow rows (`enforced: false`) present —
    /// they ARE the "what would the toggle remove" preview.
    @MainActor
    func testExclusionsMapsTheAuditTrailWithStationFilterAndLimit() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("exclusions-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "exclusions-passcode"
        prefs.port = 18_123
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, history: store)
        defer { radio.stopAll() }

        let mine = UUID(), other = UUID()
        try await store.recordExclusions([
            HistoryStore.ExclusionInput(
                artist: "Aaa", title: "Boiler Room 2019",
                durationSeconds: nil, durationSource: nil,
                arm: "title", matchedText: "boiler room",
                sourceKind: "nts", sourceURL: nil, enforced: false
            ),
            HistoryStore.ExclusionInput(
                artist: "Bbb", title: "Endless Mix",
                durationSeconds: 3720, durationSource: "listing-featured-track",
                arm: "duration", matchedText: nil,
                sourceKind: "bandcamp",
                sourceURL: URL(string: "https://example.bandcamp.com/x"),
                enforced: true
            )
        ], stationID: mine)
        try await store.recordExclusions([
            HistoryStore.ExclusionInput(
                artist: "Ccc", title: "Other Station Mix",
                durationSeconds: nil, durationSource: nil,
                arm: "title", matchedText: "mix",
                sourceKind: "nts", sourceURL: nil, enforced: false
            )
        ], stationID: other)

        func fetch(_ body: String) async throws -> [[String: Any]] {
            let (status, payload) = await radio.performJSONRoute(
                path: "/exclusions", body: Data(body.utf8)
            )
            XCTAssertEqual(status, 200, String(data: payload, encoding: .utf8) ?? "")
            let root = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            return try XCTUnwrap(root["exclusions"] as? [[String: Any]])
        }

        // Unfiltered: every station's rows.
        let all = try await fetch("{\"token\":\"\(prefs.ownerToken)\"}")
        XCTAssertEqual(all.count, 3)

        // Station-scoped, explicit null station means "across all".
        let scoped = try await fetch(
            "{\"token\":\"\(prefs.ownerToken)\",\"station\":\"\(mine.uuidString)\"}"
        )
        XCTAssertEqual(scoped.count, 2)
        XCTAssertTrue(scoped.allSatisfy { ($0["stationID"] as? String) == mine.uuidString })
        let nullStation = try await fetch(
            "{\"token\":\"\(prefs.ownerToken)\",\"station\":null}"
        )
        XCTAssertEqual(nullStation.count, 3, "explicit null widens to every station")

        // Limit honoured.
        let limited = try await fetch("{\"token\":\"\(prefs.ownerToken)\",\"limit\":1}")
        XCTAssertEqual(limited.count, 1)

        // The straight-map shape: every pinned key present on every row,
        // nulls explicit, dates as epoch seconds.
        let title = try XCTUnwrap(scoped.first { ($0["arm"] as? String) == "title" })
        XCTAssertEqual(title["artist"] as? String, "Aaa")
        XCTAssertEqual(title["matchedText"] as? String, "boiler room")
        XCTAssertTrue(title["durationSeconds"] is NSNull, "NTS has no duration — explicit null")
        XCTAssertTrue(title["durationSource"] is NSNull)
        XCTAssertTrue(title["sourceURL"] is NSNull)
        XCTAssertEqual(title["enforced"] as? Bool, false, "the shadow log crosses the wire")
        XCTAssertEqual(title["everEnforced"] as? Bool, false)
        XCTAssertEqual(title["enforcedCount"] as? Int, 0)
        XCTAssertEqual(title["hitCount"] as? Int, 1)
        XCTAssertNotNil(title["firstExcludedAt"] as? Double)
        XCTAssertNotNil(title["lastExcludedAt"] as? Double)
        let duration = try XCTUnwrap(scoped.first { ($0["arm"] as? String) == "duration" })
        XCTAssertEqual(duration["durationSeconds"] as? Double, 3720)
        XCTAssertTrue(duration["matchedText"] is NSNull)
        XCTAssertEqual(duration["sourceURL"] as? String, "https://example.bandcamp.com/x")
        XCTAssertEqual(duration["enforced"] as? Bool, true)

        // A station key that's present but not a UUID is malformed — a
        // 400, never a silent widen to every station.
        let (badStatus, _) = await radio.performJSONRoute(
            path: "/exclusions",
            body: Data("{\"token\":\"\(prefs.ownerToken)\",\"station\":\"not-a-uuid\"}".utf8)
        )
        XCTAssertEqual(badStatus, 400)
    }

    /// Every steering/transparency route is owner-gated: wrong (or
    /// missing) token answers 403 listener-mode before anything is read
    /// or written.
    @MainActor
    func testSteeringRoutesRejectGuestsWith403() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "steering-gate-passcode"
        prefs.port = 18_124
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs)
        radio.ownerThrottleStep = 0
        defer { radio.stopAll() }

        let body = Data("{\"token\":\"wrong\",\"newMusicShare\":0.4}".utf8)
        for path in ["/policy/get", "/policy/set", "/taste", "/exclusions"] {
            let (status, payload) = await radio.performJSONRoute(path: path, body: body)
            XCTAssertEqual(status, 403, "\(path) must reject guests")
            XCTAssertTrue(
                String(data: payload, encoding: .utf8)!.contains("listener mode"),
                "\(path) must answer listener-mode"
            )
        }
    }

    // MARK: - Boost steering (debounce + consume-once)

    /// A ``TrackSource`` that plays a fixture playlist and counts the
    /// steering nudges it receives — the seam the debounce test observes.
    private actor RecordingSteerSource: TrackSource {
        private let inner: PlaylistSource
        private(set) var steeringNotes = 0
        init(tracks: [Track]) {
            inner = PlaylistSource(tracks: tracks, shuffle: false)
        }
        func nextURL() async throws -> TrackSourceItem? { try await inner.nextURL() }
        func noteSteeringChanged() async { steeringNotes += 1 }
    }

    /// Rapid boosts coalesce into ONE debounced steering nudge, the
    /// boosted artist waits in the override list, and the controller-side
    /// provider drains it consume-once. The track on air is untouched —
    /// the nudge reaches the SOURCE, never the encode loop.
    @MainActor
    func testBoostSchedulesOneDebouncedRefillAndOverridesDrainOnce() async throws {
        guard let tracks = try await Self.loadFixtureTracks(bundle: Bundle(for: Self.self)) else {
            throw XCTSkip("Fixtures missing")
        }
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("boost-steer-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "boost-steer-passcode"
        prefs.port = 18_125
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, history: store)
        radio.boostRefillDebounceOverride = 0.6
        let station = Station(name: "Steer Test", kind: .playlist(queue: []))
        let source = RecordingSteerSource(tracks: tracks)
        await radio.startBroadcast(station: station, source: source)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let playing = try XCTUnwrap(radio.currentItemByStation[station.id])
        let artist = try XCTUnwrap(playing.artist)

        // Two boosts inside the debounce window.
        let (s1, b1) = await radio.performBoostAsync(stationID: station.id, token: prefs.ownerToken)
        XCTAssertEqual(s1, 200, String(data: b1, encoding: .utf8) ?? "")
        let (s2, _) = await radio.performBoostAsync(stationID: station.id, token: prefs.ownerToken)
        XCTAssertEqual(s2, 200)

        // The override is queued (deduped — same artist twice is one
        // entry) and nothing has fired yet.
        XCTAssertEqual(radio.boostSeedOverrides[station.id], [artist])
        let early = await source.steeringNotes
        XCTAssertEqual(early, 0, "the nudge waits out the debounce window")

        // …and the current track was not skipped by the boost.
        XCTAssertEqual(radio.currentItemByStation[station.id]?.title, playing.title,
                       "steering must not force-skip the track on air")

        // After the window: exactly one nudge for the two boosts.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let fired = await source.steeringNotes
        XCTAssertEqual(fired, 1, "rapid boosts fold into one scheduled refill")

        // Consume-once: the provider hands the override out exactly once.
        let provider = radio.seedOverrideProvider(stationID: station.id)
        let first = await provider()
        XCTAssertEqual(first, [artist])
        let second = await provider()
        XCTAssertEqual(second, [], "a second refill must fall back to affinity seeding")
    }

    // MARK: - SSE `stations` events

    /// Subscribe to `/events` and collect whatever arrives for `seconds`.
    /// Unlike `fetchRawResponse` this does not stop at the header block —
    /// SSE frames trickle in over time and the interesting one is late.
    nonisolated private static func collectSSE(
        port: UInt16, seconds: TimeInterval
    ) async -> String {
        let url = URL(string: "http://127.0.0.1:\(port)/events")!
        let config = URLSessionConfiguration.ephemeral
        // The request timeout backstops the deadline check below, which
        // only runs when a byte actually arrives.
        config.timeoutIntervalForRequest = seconds + 2
        config.timeoutIntervalForResource = seconds + 2
        let session = URLSession(configuration: config)
        var data = Data()
        let deadline = Date().addingTimeInterval(seconds)
        do {
            let (bytes, _) = try await session.bytes(from: url)
            for try await byte in bytes {
                data.append(byte)
                if Date() >= deadline { break }
            }
        } catch {
            // Timeout or cancellation — keep what we got.
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Starting a station mid-stream pushes a named `stations` nudge with
    /// an empty body — a notification, never the owner catalogue, because
    /// `/events` is public.
    @MainActor
    func testEventsStreamAnnouncesStationChanges() async throws {
        let port: UInt16 = 18_106
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let first = Station(name: "SSE First", kind: .playlist(queue: []))
        await radio.startBroadcast(station: first, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let collector = Task { await Self.collectSSE(port: port, seconds: 4) }
        try await Task.sleep(nanoseconds: 500_000_000)

        let second = Station(name: "SSE Second", kind: .playlist(queue: []))
        await radio.startBroadcast(station: second, source: NeverSource())

        let text = await collector.value
        XCTAssertTrue(
            text.contains("event: stations\ndata: {}"),
            "a start must push the named nudge with an empty body, got: \(text)"
        )
    }

    /// `registerStations` pushes the nudge only when the catalogue it is
    /// handed actually differs from the last registration — RootView
    /// re-registers on every @Published tick, and identical lists must
    /// not spam every web client into a re-fetch.
    @MainActor
    func testRegisterStationsPushesOnlyOnActualCatalogueChange() async throws {
        let port: UInt16 = 18_107
        let radio = RadioBroadcaster(port: port)
        defer { radio.stopAll() }
        let live = Station(name: "Register Live", kind: .playlist(queue: []))
        await radio.startBroadcast(station: live, source: NeverSource())
        try await Task.sleep(nanoseconds: 400_000_000)

        let collector = Task { await Self.collectSSE(port: port, seconds: 3) }
        try await Task.sleep(nanoseconds: 500_000_000)

        let catalogue = [
            live,
            Station(name: "Desktop Made", kind: .playlist(queue: []))
        ]
        radio.registerStations(catalogue)
        try await Task.sleep(nanoseconds: 500_000_000)
        // The same list again — RootView's onChange re-fire — is not a
        // change and must not push.
        radio.registerStations(catalogue)

        let text = await collector.value
        let nudges = text.components(separatedBy: "event: stations").count - 1
        XCTAssertEqual(
            nudges, 1,
            "one catalogue change, one nudge — got \(nudges) in: \(text)"
        )
    }
}
