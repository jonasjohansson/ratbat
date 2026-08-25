import Foundation
import AVFoundation
import AudioToolbox
import Combine
import Network
import OSLog

/// Multi-station HTTP AAC broadcaster.
///
/// Task 3.2 started as a single-pipeline spike (one station, one encoder,
/// one `/stream.aac` endpoint). Task 3.5 generalises it: each started
/// station gets its own ``BroadcastPipeline`` (encoder loop + ring buffer
/// + per-pipeline ICY state) and HTTP requests are routed by URL path:
///
/// ```
/// GET /stream/{slug}.aac   → that station's pipeline
/// GET /stream.aac          → legacy, 302-redirects to first live station
/// GET /now.json            → JSON snapshot of live stations
/// everything else          → 404
/// ```
///
/// A single shared ``NWListener`` parses the request line, extracts the
/// slug, and hands the connection off to the matching pipeline. The
/// Cloudflare tunnel is still global (one port, one forwarder) because
/// cloudflared forwards the whole TCP port — station-awareness lives
/// entirely in our HTTP layer.
///
/// The HTML/CSS/JS web player used to live here too (served from `GET /`
/// plus static asset paths). As of the architecture split it's moved to
/// the standalone `jonasjohansson/ratbat.fm` repo, hosted on GitHub Pages
/// at ratbat.jonasjohansson.se. This server exposes only the stream + JSON
/// API at radio.jonasjohansson.se.
///
/// Runs on the main actor so published UI state is safe for SwiftUI to
/// observe. The encode + serve loops offload CPU to detached tasks and
/// post progress back via `Task { @MainActor }`.
///
/// `NWListener`-based HTTP is macOS-only in practice — the iOS app doesn't
/// wire up a broadcast flow today, though the code compiles on both so
/// we're not boxed into macOS forever.
@MainActor
public final class RadioBroadcaster: ObservableObject {
    // MARK: - Published state

    /// Station IDs whose pipelines are currently running. `Set` because
    /// the UI only asks "is this one live?" — order doesn't matter.
    @Published public private(set) var broadcasting: Set<Station.ID> = []
    /// Per-station listener counts. Absent key = zero.
    @Published public private(set) var listenerCount: [Station.ID: Int] = [:]
    /// Per-station currently-encoding item. Drives ICY `StreamTitle`
    /// updates and the "Now: Artist — Title" UI snippet. `TrackSourceItem`
    /// (not `Track`) so NTS-backed stations — which don't have a full
    /// library ``Track`` — can publish the same way as playlist stations.
    @Published public private(set) var currentItemByStation: [Station.ID: TrackSourceItem] = [:]

    /// When each station's current track began playing out, so `/now.json`
    /// can say how far into it the broadcast is.
    ///
    /// Nothing else on the wire carried this, and a listener cannot infer
    /// it: a browser that joins a live stream three minutes into a track
    /// has no way to know, so it started its own clock at zero and showed
    /// `0:00 / 6:30` for something two thirds gone. Stamped in
    /// ``updateCurrentItem`` — the one place a track becomes current, and
    /// called once per track, right after the decoder opens the file.
    private var currentItemStartedAt: [Station.ID: Date] = [:]
    /// Per-station prefetched next track. The encode loop resolves one
    /// track ahead (the dropout fix); publishing it lets /now.json show
    /// a truthful "next" — the only future track that's actually certain.
    @Published public private(set) var upcomingByStation: [Station.ID: TrackSourceItem] = [:]

    /// A just-finished track, retired into the per-station recent ring.
    /// `entryID` gives the web player a stable handle for retro-♥ ("the
    /// one that got away, two tracks back").
    struct RecentTrack: Sendable {
        let entryID: UUID
        let item: TrackSourceItem
        let playedAt: Date
    }
    /// Newest-first, capped at ``recentRingCapacity``.
    ///
    /// Seeded from ``HistoryStore`` at broadcast start and topped up in
    /// memory as tracks retire. The in-memory-only version was empty on
    /// every poll in practice, for two compounding reasons: it reset on
    /// every restart, and with no listener attached the encode loop parks
    /// after track one (the data-conscious idle) so nothing ever retires.
    /// A field that is always `[]` tells a client less than no field at all.
    private(set) var recentByStation: [Station.ID: [RecentTrack]] = [:]

    /// How many just-played tracks each station keeps. Also the number of
    /// history rows the seed reads back at broadcast start.
    static let recentRingCapacity = 5

    /// Embedded cover art, keyed by ``TrackFileProbe/artworkID(for:)`` and
    /// served from `GET /artwork/{id}.jpg`.
    ///
    /// Only local files land here — a generative track's art already has a
    /// perfectly good URL on the source's own CDN and there is no reason to
    /// proxy it. Bounded to a few entries beyond the recent ring so a
    /// client rendering "what just played" can still fetch each tile.
    private var artworkCache: [String: Data] = [:]
    private var artworkOrder: [String] = []
    private static let artworkCacheLimit = 16

    /// Last error surfaced by the listener or any encode/decode loop.
    /// String-typed so the UI can just render it; OSLog has the details.
    @Published public private(set) var error: String?
    /// Flips to `true` when the user changes a broadcast-affecting setting
    /// (quality, sample rate, port, ICY) while at least one station is
    /// live. Clients display a banner asking the user to restart; stopAll()
    /// clears it because the next start will pick up the new values.
    @Published public private(set) var needsRestart: Bool = false

    #if os(macOS)
    /// Public tunnel that exposes the whole port out to the internet via
    /// cloudflared. Started lazily the first time any station begins
    /// broadcasting, stopped when the last station stops. Single tunnel
    /// for all stations since cloudflared is port-scoped.
    public let tunnel: CloudflareTunnel = CloudflareTunnel()
    #endif

    /// The broadcaster the app is currently driving, for code that cannot
    /// be handed one directly.
    ///
    /// Exists for the macOS app delegate: `applicationWillTerminate` is an
    /// AppKit callback in the app target, and the view that owns the
    /// broadcaster lives down here in the framework, so there is no way to
    /// pass a reference up. `RootView` publishes it here on appear.
    ///
    /// `weak` on purpose — a termination hook must never be the thing
    /// keeping the broadcaster alive. Tests construct many broadcasters and
    /// harmlessly overwrite this; nothing reads it except the delegate.
    @MainActor public static weak var current: RadioBroadcaster?

    /// Whether starting a station may open the public tunnel.
    ///
    /// Defaults to `false` under XCTest. `namedTunnelConfigured()` only
    /// checks that `~/.cloudflared/config.yml` exists, so on the mac-mini
    /// every broadcasting test used to spawn a real `cloudflared tunnel
    /// run` against the *production* hostname and orphan it — eight live
    /// connectors after one suite run, all competing for the same named
    /// tunnel as the actual radio.
    public let publishesPublicly: Bool

    /// True when the process is hosting an XCTest bundle.
    ///
    /// `XCTestConfigurationFilePath` is set by the test runner for both
    /// `xcodebuild test` and Xcode's test action, and is absent in a
    /// normally-launched app.
    /// Test hook: reports the thread the encode loop actually starts on.
    ///
    /// The loop is launched with `Task.detached`, but that only detaches if
    /// the function is `nonisolated`. A `static func` on a `@MainActor`
    /// class inherits the actor, so `await Self.runEncodeLoop(...)` hopped
    /// straight back to the main thread and did the AVAudioFile reads and
    /// the AAC encode there. This exists so that is provable rather than
    /// argued.
    nonisolated(unsafe) static var encodeLoopThreadObserver: (@Sendable (Bool) -> Void)?

    /// Why a station's encode loop stopped.
    ///
    /// Running dry is the one shutdown that is graceful by design, so it
    /// left no crash report, no error-level log and no on-disk marker —
    /// both the exhaustion notice and the loop exit were `.info`, which
    /// this machine does not persist. At 09:00 the station was simply
    /// absent, with nothing to say when or why it went off air.
    public enum OffAirReason: Equatable, Sendable {
        /// The source returned nil — pool exhausted, playlist empty.
        ///
        /// There is deliberately no `sourceError` case. A thrown error is
        /// a fault, never a statement that the music ran out, so the encode
        /// loop retries it with backoff instead of folding the station —
        /// see `sourceErrorBackoff`. Only `nil` ends a station.
        case exhausted

        /// The task was cancelled: a deliberate stop, or app shutdown.
        case cancelled

        public var label: String {
            switch self {
            case .exhausted: return "exhausted"
            case .cancelled: return "cancelled"
            }
        }
    }

    /// When and why each station last went off air. Survives in memory for
    /// the UI and `/now.json`; the matching log line is emitted at a level
    /// the unified log actually keeps.
    public struct OffAirRecord: Equatable, Sendable {
        public let reason: OffAirReason
        public let at: Date
        public let trackIndex: Int
    }

    @Published public private(set) var lastOffAir: [Station.ID: OffAirRecord] = [:]

    // MARK: - Stream pacing

    /// How far ahead of real time the encode loop is allowed to run: the
    /// runway a listener's buffer holds against a stalled read (a slow
    /// Drive block fetch, a track boundary that has to open a file).
    ///
    /// It is also the floor on how far behind `/now.json` the audio runs,
    /// which is why it rides the wire — the web client subtracts it when
    /// deciding *when* to show a track change, so that the title flips as
    /// the track arrives in your ears rather than as it leaves the Mac.
    nonisolated public static let broadcastLeadSeconds: Double = 5

    /// Monotonic seconds, for pacing only. `Date` is wall time and can
    /// step (NTP correction, the user changing the clock); a backwards
    /// step would stall the encoder for the length of the jump and take
    /// every listener down with it.
    nonisolated static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// One step of the encode loop's pacing.
    ///
    /// `playoutHead` is the instant at which the audio written so far
    /// would finish playing. Having just written `chunkSeconds` of audio,
    /// this advances the head and says how long to wait before writing
    /// more — nothing at all while the head is still within `lead` of the
    /// wall clock, so the encoder keeps a constant runway ahead of the
    /// listener and never accumulates drift.
    ///
    /// Pulled out of the loop because it is the arithmetic that was wrong:
    /// a flat sleep per chunk is a *rate multiplier*, not a lead, and no
    /// amount of reading the loop made that visible. Here it can be asked
    /// directly.
    nonisolated static func pace(
        playoutHead: Double,
        now: Double,
        chunkSeconds: Double,
        lead: Double
    ) -> (head: Double, sleep: Double) {
        let head = playoutHead + chunkSeconds
        // Behind real time: a slow decode, or the first chunk after the
        // listener gate released. Re-anchor rather than sprint to repay
        // the debt — sprinting hands the listener a burst of audio and
        // desyncs them all over again, which is the whole bug.
        guard head >= now else { return (now, 0) }
        return (head, max(0, head - now - lead))
    }

    // MARK: - Heartbeat

    /// How often each live station records that it is still on air.
    nonisolated public static let heartbeatInterval: TimeInterval = 60
    /// How long heartbeat rows are kept.
    nonisolated public static let heartbeatRetention: TimeInterval = 30 * 86_400

    private var heartbeatTask: Task<Void, Never>?

    /// Write one row per live station per interval, so that afterwards
    /// "off air" and "on air but nobody queued anything" can be told
    /// apart. history.db alone records a row only when a track plays, so
    /// those two look identical — which is why an overnight outage could
    /// not be dated.
    private func startHeartbeatIfNeeded() {
        #if os(macOS)
        guard heartbeatTask == nil, history != nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let live = await MainActor.run { Array(self.broadcasting) }
                guard !live.isEmpty else {
                    try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                    continue
                }
                for stationID in live {
                    let listeners = await MainActor.run { self.listenerCount[stationID] ?? 0 }
                    if let store = await MainActor.run(body: { self.history }) {
                        try? await store.recordHeartbeat(station: stationID, listeners: listeners)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
            }
        }
        #endif
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Launch resume

    /// Delay before resume attempt `attempt`. Same 1s→30s shape and
    /// ceiling as the other retry loops in this file.
    nonisolated public static func resumeRetryDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 1 }
        return min(30, pow(2, Double(attempt - 1)))
    }

    /// Bring back the stations that were live before, concurrently and
    /// with retries.
    ///
    /// This used to be a plain `for … { await startBroadcast(…) }` at the
    /// call site, run once per launch behind a `didAutoStart` flag. Two
    /// problems, both of which cost airtime:
    ///
    /// - **Head-of-line blocking.** A generative station's
    ///   `startBroadcast` awaits `downloadService.ensureReady()`, the
    ///   Python venv bootstrap — 30–60s on a cold start. Every station
    ///   behind it waited, and so did the listener and tunnel, which only
    ///   come up as a side effect of the first station starting. Seen for
    ///   real during the 065c4f0 deploy: one station audible while the
    ///   second still returned 502.
    /// - **One shot.** A station that failed to start was gone until the
    ///   next launch, with nothing to notice or retry — the same shape as
    ///   the tunnel that never came back.
    ///
    /// `start` and `isLive` are injectable so the policy is testable
    /// without a venv, a network, or a real generative source.
    @MainActor
    public func resumeStations(
        _ all: [Station],
        matching slugs: Set<String>,
        maxAttempts: Int = 4,
        retryDelayOverride: TimeInterval? = nil,
        start: (@Sendable @MainActor (Station) async -> Void)? = nil,
        isLive: (@Sendable @MainActor (Station) async -> Bool)? = nil
    ) async {
        let wanted = all.filter { slugs.contains($0.slug) }
        guard !wanted.isEmpty else { return }

        let doStart = start ?? { [weak self] station in
            await self?.startBroadcast(station: station)
        }
        let checkLive = isLive ?? { [weak self] station in
            self?.isBroadcasting(stationID: station.id) ?? false
        }

        logger.notice(
            "resuming \(wanted.count, privacy: .public) station(s) concurrently"
        )

        var running: [Task<Void, Never>] = []
        for station in wanted {
            running.append(
                Task { @MainActor in
                    for attempt in 1...max(1, maxAttempts) {
                        await doStart(station)
                        if await checkLive(station) { return }
                        guard attempt < max(1, maxAttempts) else { break }
                        let delay = retryDelayOverride
                            ?? Self.resumeRetryDelay(forAttempt: attempt)
                        if delay > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                    }
                    self.logger.error(
                        "resume gave up on \(station.slug, privacy: .public) after \(max(1, maxAttempts), privacy: .public) attempts"
                    )
                }
            )
        }
        // Await them all so the caller knows resume is settled — but they
        // ran concurrently, so one slow bootstrap no longer gates the rest.
        for task in running { await task.value }
    }

    // MARK: - First-listener signalling

    /// Encode loops parked waiting for a first listener, by station.
    private var listenerWaiters: [Station.ID: [CheckedContinuation<Void, Never>]] = [:]

    /// Suspend until a listener connects to `stationID`.
    ///
    /// Replaces a 5-second polling sleep, which meant the first listener on
    /// an idle station — the normal state of a personal radio — waited 0–5s
    /// with no bytes flowing.
    @MainActor
    public func awaitFirstListener(stationID: Station.ID) async {
        if (listenerCount[stationID] ?? 0) > 0 { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || (listenerCount[stationID] ?? 0) > 0 {
                    cont.resume()
                    return
                }
                listenerWaiters[stationID, default: []].append(cont)
            }
        } onCancel: {
            // Without this a stopped station leaves its encode task
            // suspended forever.
            Task { @MainActor [weak self] in
                self?.signalListenerArrived(stationID: stationID)
            }
        }
    }

    /// Wake everything parked on `stationID`. Idempotent.
    @MainActor
    public func signalListenerArrived(stationID: Station.ID) {
        guard let waiters = listenerWaiters.removeValue(forKey: stationID) else { return }
        for waiter in waiters { waiter.resume() }
    }

    /// A station currently retrying past a transient source failure.
    ///
    /// It is still on air and still registered, so nothing else would say
    /// so — and a station that is live but silently retrying is exactly
    /// the state that used to be invisible.
    public struct SourceRetryRecord: Equatable, Sendable {
        public let attempt: Int
        public let reason: String
        public let since: Date
    }

    @Published public private(set) var sourceRetries: [Station.ID: SourceRetryRecord] = [:]

    func recordSourceRetry(stationID: Station.ID, attempt: Int, reason: String) {
        // Keep the ORIGINAL `since` across a run of retries: what matters
        // is how long this station has been struggling, not when the most
        // recent attempt was.
        let since = sourceRetries[stationID]?.since ?? Date()
        sourceRetries[stationID] = SourceRetryRecord(
            attempt: attempt,
            reason: reason,
            since: since
        )
    }

    func clearSourceRetry(stationID: Station.ID) {
        sourceRetries.removeValue(forKey: stationID)
    }

    /// Record an off-air transition. Called from the encode loop's unwind.
    func recordOffAir(stationID: Station.ID, reason: OffAirReason, trackIndex: Int) {
        lastOffAir[stationID] = OffAirRecord(
            reason: reason,
            at: Date(),
            trackIndex: trackIndex
        )
    }

    /// How long to wait after `consecutiveFailures` failed opens in a row.
    ///
    /// Zero for the first few: a handful of dead entries in an otherwise
    /// healthy library should be skipped at full speed, and a station that
    /// hits one bad file must not stutter. Sustained failure means
    /// something structural — the volume unmounted, the folder moved — so
    /// back off geometrically instead of spinning a core.
    ///
    /// Deliberately never gives up. A station that stops retrying cannot
    /// come back when the volume returns, and self-healing is the point.
    /// How long to wait after `consecutiveFailures` source errors in a row.
    ///
    /// 1s doubling to a 30s cap — the same ceiling as
    /// ``openFailureBackoff(consecutiveFailures:)`` and
    /// ``listenerRebindDelay(forAttempt:)``. A shared cap matters: these
    /// three retry loops can all be backing off at once during a general
    /// outage, and a common ceiling means the worst case is one cap, not
    /// the product of three.
    ///
    /// Starts at 1s rather than 0 because, unlike a dead file, a failed
    /// resolve is never worth retrying instantly — whatever broke needs a
    /// moment.
    nonisolated public static func sourceErrorBackoff(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 1 else { return 1 }
        return min(30, pow(2, Double(consecutiveFailures - 1)))
    }

    nonisolated public static func openFailureBackoff(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 3 else { return 0 }
        return min(30, 0.5 * pow(2, Double(consecutiveFailures - 4)))
    }

    nonisolated public static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Config

    private let port: NWEndpoint.Port
    /// Internal (not private) because the `/stations/*` route handlers
    /// live in StationWire.swift — same type, different file — and read
    /// the owner token, Last.fm key and auto-start membership off it.
    let preferences: BroadcastPreferences
    private var preferencesSubscription: AnyCancellable?

    // MARK: - Catalogue seam

    /// Injected catalogue capabilities for the web control plane. The
    /// broadcaster deliberately does not hold `StationManager` (see the
    /// comment at ``stationNames``) — `RootView` wires these closures at
    /// storage-attach time, the same idiom as `selectionPolicyProvider`.
    /// All `nil` until then; every `/stations/*` handler that needs one
    /// answers `503 catalogue unavailable` while it is.
    public var listStations: (@MainActor () -> [Station])?
    /// Create a validated generative station (throws
    /// ``StationManager/StationEditError``); the returned station carries
    /// its actual, possibly collision-bumped, name.
    public var createStation: (@MainActor (StationDraft, String?) throws -> Station)?
    /// Apply a sparse ``StationUpdate`` (throws the same error set).
    public var updateStation: (@MainActor (Station.ID, StationUpdate) throws -> Station)?
    /// Remove a station; `false` means the id resolved to nothing.
    public var deleteStation: (@MainActor (Station.ID) -> Bool)?
    /// Flip a station's launch-time auto-start flag (enabled, slug).
    /// Auto-start membership lives in slug-keyed per-machine preferences,
    /// so the write goes through the seam like every other mutation the
    /// web can cause — the broadcaster stays a reader.
    public var setAutoStart: (@MainActor (Bool, String) -> Void)?
    /// Read-only view of the indexed library, for Library Radio pools.
    /// The same injected-closure idiom as the catalogue seam and for the
    /// same reason: the library lives on `LibraryViewModel`, which the
    /// broadcaster deliberately never holds. Re-read at every pool
    /// refill so a rescan reaches a live station without a restart.
    /// `nil` until RootView wires it — starting a Library Radio station
    /// before then surfaces an error instead of broadcasting silence.
    public var libraryTracks: (@MainActor () -> [Track])?

    /// Failed-attempt throttle state for ``ownerGate(_:)``. The three
    /// knobs are `var`s rather than constants only so the tests that
    /// deliberately hammer the guest path can zero the delay and stay
    /// fast — production never assigns them.
    private(set) var failedOwnerAttempts = 0
    var ownerFreeAttempts = 3
    var ownerThrottleStep: TimeInterval = 0.5
    var ownerThrottleCeiling: TimeInterval = 5
    private let logger = Logger(
        subsystem: RatbatLog.subsystem,
        category: "broadcaster"
    )

    #if os(macOS)
    /// Optional NTS-stack dependencies. `nil` in test / minimal-init
    /// configurations; an attempt to broadcast an NTS station without
    /// these wired up logs an error and bails instead of crashing.
    private let downloadService: DownloadService?
    private let nts: NTSClient?
    /// Internal (not private) for the same reason ``preferences`` is:
    /// the `/taste` and `/exclusions` handlers live in SteeringWire.swift
    /// — same type, different file — and read their rows off it.
    let history: HistoryStore?
    /// Read-side handle on the user's music folder. Used by the ♥ save
    /// flow to know where to copy cached files. `nil` in test configs;
    /// `handleLike` returns a 500 when it's missing.
    private let libraryConfig: LibraryConfig?
    /// Locally-derived taste signals shared across every generative
    /// station. Optional so minimal-init tests can skip it — stations
    /// built without a profile just get an empty profile's zero-valued
    /// scores, which degrades to near-random selection rather than
    /// crashing. Internal so SteeringWire.swift's `/taste` handler can
    /// publish the snapshot.
    let tasteProfile: TasteProfile?
    /// Long-lived MusicBrainz client shared across every Last.fm /
    /// Bandcamp station so the per-artist / per-recording caches
    /// accumulate across pool refills and across stations. Eagerly
    /// constructed at broadcaster init — the constructor makes no
    /// network calls, so the cost is negligible, and eager init
    /// removes a benign TOCTOU race between two concurrent
    /// `startBroadcast` calls both lazy-initing the shared client.
    /// Internal (not private) for the same reason ``preferences`` is:
    /// the `/trackinfo` handler lives in TrackInfoWire.swift — same
    /// type, different file — and asks it for country + release year.
    let musicBrainz: MusicBrainzClient
    /// Long-lived Bandcamp discover client. Same rationale as
    /// ``musicBrainz``: per-actor request throttling is more useful
    /// when the throttle gate survives across stations / refills,
    /// and the constructor is network-free so eager init is free.
    private let bandcamp: BandcampClient
    /// Long-lived Last.fm client for `/trackinfo`, tagged with the API
    /// key it was built with. `lastFMClientIfAvailable()` deliberately
    /// builds a FRESH client per call so key changes bite immediately —
    /// but a fresh actor also means fresh caches, and `/trackinfo`'s
    /// whole cost model rests on ``LastFMClient/artistInfo(_:)``'s 24h
    /// TTL + single-flight caches surviving between polls. This slot
    /// keeps one client alive per key; a changed key still bites,
    /// because the handler rebuilds the slot the moment the stored key
    /// stops matching (see `lastFMForTrackInfo()` in TrackInfoWire.swift).
    var trackInfoLastFM: (apiKey: String, client: LastFMClient)?
    /// MusicBrainz seam for `/trackinfo`. Production leaves it nil and
    /// the shared ``musicBrainz`` client answers; the socket tests
    /// install a canned lookup so the suite never touches
    /// musicbrainz.org. Same tests-only-assign posture as
    /// ``ownerFreeAttempts``.
    var trackInfoMusicBrainzOverride: (any MusicBrainzLookup)?
    #endif

    // MARK: - Internals

    /// Per-station encode/serve state. Non-Sendable because it's always
    /// accessed from the main actor; the detached tasks inside only hold
    /// weak refs to the broadcaster and reach back through `MainActor.run`.
    private final class BroadcastPipeline {
        /// Identity for this particular run of the station.
        ///
        /// A cancelled encode loop can outlive its cancellation while
        /// parked on an unstructured prefetch, so `stationID` alone does
        /// not tell the exit block whether the pipeline it is about to
        /// fold is still its own — or the freshly restarted one that
        /// replaced it.
        let token = UUID()
        /// Refreshed by ``RadioBroadcaster/registerStations(_:)`` when the
        /// user edits a live station. It used to be a `let` snapshotted at
        /// broadcast start, which is why `/now.json` and `/history` kept
        /// publishing a station's pre-rename name until the next restart.
        var station: Station
        let buffer: AACRingBuffer
        /// Encoder bitrate this pipeline was started with. Frozen at
        /// construction — AACEncoder doesn't support live bitrate changes,
        /// so a live pipeline keeps its original setting until stopped.
        let bitrate: Int
        let sampleRate: Double
        /// Human-readable folder name for the ♥ save flow, without having
        /// to reach into the (separately-owned) StationManager. Tracks
        /// ``station`` rather than freezing at start, so a ♥ after a rename
        /// files under the name the user can actually see. Anything already
        /// saved keeps its old folder.
        var stationName: String { station.name }
        var encodeTask: Task<Void, Never>?
        /// Flipped `true` by ``RadioBroadcaster/skipCurrent(stationID:)``
        /// when the user hits 👎. The encode loop's inner PCM loop reads
        /// and clears it, breaking out of the current decoded track so
        /// the outer loop advances. Avoids the complexity of cancelling
        /// the decoder mid-track.
        var skipRequested: Bool = false
        /// The live source feeding this pipeline's encode loop. Held here
        /// (and not only captured by the loop) so boost steering's
        /// debounced refill can reach the running station's source —
        /// `pipelines[id]?.source.noteSteeringChanged()` — without
        /// plumbing a side channel into the loop.
        let source: TrackSource

        init(
            station: Station,
            buffer: AACRingBuffer,
            bitrate: Int,
            sampleRate: Double,
            source: TrackSource
        ) {
            self.station = station
            self.buffer = buffer
            self.bitrate = bitrate
            self.sampleRate = sampleRate
            self.source = source
        }
    }

    private var pipelines: [Station.ID: BroadcastPipeline] = [:]

    // MARK: - Boost steering

    /// Artists the owner boosted on each station since its last refill,
    /// most recent first, capped at 3 (case-insensitive dedup). Drained
    /// consume-once by ``seedOverrideProvider(stationID:)`` so a natural
    /// refill that beats the debounced one still steers exactly once —
    /// the override must never keep re-front-loading every refill after
    /// the gesture (that is `topAffinityArtists`' job, with decay).
    /// Internal for the consume-once test.
    var boostSeedOverrides: [Station.ID: [String]] = [:]

    /// One pending debounced-refill task per station. A boost inside the
    /// window folds into the pending task by only appending to the
    /// override list — "one scheduled refill per station per few
    /// minutes", so boosting five tracks in a minute cannot hammer the
    /// sources with five refills.
    private var boostRefillTasks: [Station.ID: Task<Void, Never>] = [:]

    /// How long a boost waits before nudging the station's source to
    /// refill. Long enough to coalesce a burst of boosts, short enough
    /// that "more of this" is audible within a couple of tracks.
    nonisolated static let boostRefillDebounce: TimeInterval = 120

    /// Test override for the debounce window — the
    /// `listenerRebindDelay(forAttempt:)` precedent: production never
    /// assigns it, tests set it to something a test can afford to wait.
    var boostRefillDebounceOverride: TimeInterval?

    /// Display names for every station the user has saved, live or not —
    /// see ``registerStations(_:)``. Absent id means "we have never heard
    /// of this station", which is how `/history` distinguishes a deleted
    /// station from one that simply isn't on air.
    private var stationNames: [Station.ID: String] = [:]
    /// Slugs, maintained in lockstep with ``stationNames``. `/health`
    /// reports stations that heartbeated earlier today but aren't live
    /// now — no pipeline to read a slug off, and the slug can't be
    /// recomputed from the name alone (its empty-name fallback embeds the
    /// station's own uuid), so it has to be remembered like the name is.
    private var stationSlugs: [Station.ID: String] = [:]
    /// The list handed to the most recent ``registerStations(_:)`` call,
    /// verbatim. Exists only so the next call can tell "the catalogue
    /// actually changed" from "RootView re-registered the same list" and
    /// push the `stations` SSE nudge only for the former. Full `Station`
    /// values, not names — a query-only edit changes nothing about a
    /// station's name or slug but is still a change the web must hear.
    private var lastRegisteredStations: [Station] = []
    /// When this broadcaster came up. `/health` reports the difference as
    /// `uptimeSeconds` — the broadcaster lives for the whole process, so
    /// this is effectively app uptime, which is what "● on air · 3d 4h"
    /// on the web wants to say.
    private let startedAt = Date()
    private var listener: NWListener?
    /// Connected clients keyed by connection identity. We store the
    /// station each client is bound to so disconnects decrement the
    /// right listener count.
    private var clients: [ObjectIdentifier: (connection: NWConnection, stationID: Station.ID)] = [:]
    private var clientTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Server-Sent Events subscribers — clients on `GET /events` that want
    /// a live push of the now-playing snapshot whenever a track changes or
    /// the listener count moves, instead of polling `/now.json`. Keyed by
    /// connection identity so a disconnect drops the right one.
    private var sseSubscribers: [ObjectIdentifier: NWConnection] = [:]
    /// Consecutive listener rebind attempts, reset when it reaches .ready.
    private var listenerRebindAttempt = 0
    private var listenerRebindTask: Task<Void, Never>?

    /// Construct a broadcaster bound to a specific port. Primarily for
    /// tests that need deterministic ports without trampling the
    /// user-facing preferences — production callers should prefer
    /// ``init(preferences:downloadService:nts:history:)``.
    public init(port: UInt16 = 18000, publishesPublicly: Bool? = nil) {
        // Force-unwrap: NWEndpoint.Port(rawValue:) only returns nil for 0.
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
        self.preferences = BroadcastPreferences.shared
        self.publishesPublicly = publishesPublicly ?? !Self.isRunningUnderXCTest
        #if os(macOS)
        self.downloadService = nil
        self.nts = nil
        self.history = nil
        self.libraryConfig = nil
        self.tasteProfile = nil
        self.musicBrainz = MusicBrainzClient(userAgent: "Ratbat/1.0 (jns.johansson@gmail.com)")
        self.bandcamp = BandcampClient(userAgent: "Ratbat/1.0 (jns.johansson@gmail.com)")
        #endif
        subscribeToPreferences()
    }

    #if os(macOS)
    /// Construct a broadcaster backed by a user preferences store and the
    /// shared NTS stack dependencies (optional so existing tests can skip
    /// them). The broadcaster snapshots `prefs.port` at init time — live
    /// port changes require stopAll + re-init (flagged via
    /// ``needsRestart``). Quality and sample-rate changes also flag a
    /// restart but can be picked up on the next startBroadcast without
    /// recreating the broadcaster.
    public init(
        preferences: BroadcastPreferences,
        downloadService: DownloadService? = nil,
        nts: NTSClient? = nil,
        history: HistoryStore? = nil,
        libraryConfig: LibraryConfig? = nil,
        tasteProfile: TasteProfile? = nil,
        publishesPublicly: Bool? = nil
    ) {
        self.preferences = preferences
        self.publishesPublicly = publishesPublicly ?? !Self.isRunningUnderXCTest
        let raw = UInt16(clamping: preferences.port)
        self.port = NWEndpoint.Port(rawValue: raw) ?? .any
        self.downloadService = downloadService
        self.nts = nts
        self.history = history
        self.libraryConfig = libraryConfig
        self.tasteProfile = tasteProfile
        self.musicBrainz = MusicBrainzClient(userAgent: "Ratbat/1.0 (jns.johansson@gmail.com)")
        self.bandcamp = BandcampClient(userAgent: "Ratbat/1.0 (jns.johansson@gmail.com)")
        subscribeToPreferences()
    }
    #else
    /// iOS flavour keeps the tighter surface area — no NTS / tunnel / venv
    /// wiring on that platform today.
    public init(preferences: BroadcastPreferences, publishesPublicly: Bool? = nil) {
        self.preferences = preferences
        self.publishesPublicly = publishesPublicly ?? !Self.isRunningUnderXCTest
        let raw = UInt16(clamping: preferences.port)
        self.port = NWEndpoint.Port(rawValue: raw) ?? .any
        subscribeToPreferences()
    }
    #endif

    /// Wire up the "prefs changed → needsRestart while broadcasting" loop.
    /// ``BroadcastPreferences.revision`` ticks whenever any tracked value
    /// mutates, so a single sink covers every field.
    private func subscribeToPreferences() {
        preferencesSubscription = preferences.$revision
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                // Only nag the user when something's actually live.
                if !self.broadcasting.isEmpty {
                    self.needsRestart = true
                }
            }
    }

    // MARK: - Public API

    /// Convenience entry point. Branches on the station's ``Station/Kind``:
    /// playlist stations wrap their fixed queue in a ``PlaylistSource``;
    /// NTS/Last.fm stations spin up the matching controller backed by the
    /// broadcaster's injected dependencies.
    public func startBroadcast(station: Station) async {
        // Match pre-refactor ordering: skip silently if already live, then
        // surface any variant-specific validation before spinning up a source.
        guard !broadcasting.contains(station.id) else { return }

        switch station.kind {
        case .playlist(let queue):
            guard !queue.isEmpty else {
                error = "Cannot broadcast an empty queue"
                return
            }
            // Wire history recording so playlist plays land in the same
            // store as generative ones (macOS only — the store is
            // platform-gated, so the closure stays nil on iOS).
            #if os(macOS)
            let stationID = station.id
            // Definite-initialization rather than `history.map { … }`:
            // a `.map` returning a closure trips a Swift type-inference
            // bug ("failed to produce diagnostic for expression") — the
            // same one hit by the play-through hook.
            let recorder: (@Sendable (String, String, URL) async -> Int64?)?
            if let store = history {
                recorder = { (artist: String, title: String, url: URL) async -> Int64? in
                    try? await store.record(
                        station: stationID,
                        artist: artist,
                        title: title,
                        cachedPath: url.path
                    )
                }
            } else {
                recorder = nil
            }
            #else
            let recorder: (@Sendable (String, String, URL) async -> Int64?)? = nil
            #endif
            // Second closure, same reason as `recorder` above: the
            // exclusion rows have to reach the macOS-only store from a
            // cross-platform actor.
            #if os(macOS)
            let exclusionRecorder: (@Sendable ([SelectionExclusionRecord]) async -> Void)?
            if let store = history {
                exclusionRecorder = { (rows: [SelectionExclusionRecord]) async -> Void in
                    try? await store.recordExclusions(
                        rows.map(HistoryStore.ExclusionInput.init),
                        stationID: stationID
                    )
                }
            } else {
                exclusionRecorder = nil
            }
            #else
            let exclusionRecorder: (@Sendable ([SelectionExclusionRecord]) async -> Void)? = nil
            #endif
            let source = PlaylistSource(
                tracks: queue,
                recordPlay: recorder,
                selectionPolicy: selectionPolicyProvider(),
                recordExclusions: exclusionRecorder
            )
            await startBroadcast(station: station, source: source)

        case .nts(let config):
            #if os(macOS)
            guard let source = await makeNTSSource(config: config) else {
                return
            }
            await startBroadcast(station: station, source: source)
            #else
            error = "NTS stations are macOS-only"
            #endif

        case .lastFM(let config):
            #if os(macOS)
            guard let source = await makeLastFMSource(config: config) else {
                return
            }
            await startBroadcast(station: station, source: source)
            #else
            error = "Last.fm stations are macOS-only"
            #endif

        #if os(macOS)
        case .bandcamp(let config):
            guard let source = await makeBandcampSource(config: config) else {
                return
            }
            await startBroadcast(station: station, source: source)
        #endif

        case .libraryRadio(let config):
            #if os(macOS)
            guard let source = makeLibraryRadioSource(config: config) else {
                return
            }
            await startBroadcast(station: station, source: source)
            #else
            error = "Library Radio stations are macOS-only"
            #endif
        }
    }

    /// A LIVE read of the selection policy, for a station actor to call.
    ///
    /// Note what this deliberately is NOT: a value. Every other preference
    /// that crosses into the pipeline is snapshotted at broadcast start —
    /// see the bitrate/sampleRate comment in `startBroadcast(station:source:)`
    /// and `lastFMClientIfAvailable`'s "takes effect on the next broadcast
    /// start". Doing that here would freeze both dials for the whole
    /// broadcast, and `selectionPolicy` deliberately does not tick
    /// `revision`, so there would be no "needs restart" nag to tell the
    /// owner why nothing happened. This closure re-reads `preferences` on
    /// every call instead, and the controllers call it at every refill.
    ///
    /// Captures the INJECTED `preferences`, not `BroadcastPreferences.shared`,
    /// so a test that injects its own object is driving the thing it
    /// configured.
    private func selectionPolicyProvider() -> @Sendable () async -> SelectionPolicy {
        let prefs = preferences
        return { await MainActor.run { prefs.selectionPolicy } }
    }

    /// Live read of a station's boost-seed overrides for its controller,
    /// same idiom as ``selectionPolicyProvider()``. Consume-once: the
    /// read REMOVES the entry, so whichever refill happens first — the
    /// debounced one this class schedules, or a natural pool-empty
    /// refill that beats it — steers, and later refills fall back to
    /// affinity seeding alone. Internal so the consume-once contract is
    /// testable directly.
    func seedOverrideProvider(stationID: Station.ID) -> @Sendable () async -> [String] {
        { [weak self] in
            await MainActor.run {
                guard let self else { return [] }
                return self.boostSeedOverrides.removeValue(forKey: stationID) ?? []
            }
        }
    }

    /// The steering half of a successful boost: remember the artist for
    /// the station's next pool refill and schedule the debounced nudge
    /// that triggers it. Never touches the needle — the source decides
    /// what a steering note means, and every source finishes the current
    /// track regardless.
    private func noteBoostSteering(stationID: Station.ID, artist: String?) {
        guard let artist = artist?.trimmingCharacters(in: .whitespaces),
              !artist.isEmpty else { return }
        var overrides = boostSeedOverrides[stationID] ?? []
        overrides.removeAll { $0.caseInsensitiveCompare(artist) == .orderedSame }
        overrides.insert(artist, at: 0)
        boostSeedOverrides[stationID] = Array(overrides.prefix(3))

        // One pending task per station; boosts inside the window already
        // folded themselves in by appending to the override list above.
        guard boostRefillTasks[stationID] == nil else { return }
        let delay = boostRefillDebounceOverride ?? Self.boostRefillDebounce
        boostRefillTasks[stationID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            // Clear the slot before the nudge so a boost arriving while
            // the source refills starts a fresh window instead of being
            // silently swallowed.
            self.boostRefillTasks[stationID] = nil
            // A station stopped inside the window simply has no pipeline
            // any more — the note evaporates, which is correct: its next
            // start builds a fresh pool through the affinity seeds the
            // boost already earned.
            await self.pipelines[stationID]?.source.noteSteeringChanged()
        }
    }

    #if os(macOS)
    /// Resolve an ``NTSStationController`` + ``NTSSource`` from the injected
    /// dependencies. Returns nil and surfaces an error if the broadcaster
    /// wasn't constructed with an NTS stack, or if the Python venv fails
    /// to bootstrap. First-call cost is high (venv install); subsequent
    /// calls are cheap because ``DownloadService/ensureReady()`` is a no-op
    /// once the venv is built.
    private func makeNTSSource(config: NTSStationConfig) async -> NTSSource? {
        guard let downloadService, let nts, let history else {
            let msg = "NTS station requires broadcaster NTS dependencies (downloadService/nts/history) — none injected"
            error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        // Ensure the shared Python venv is ready. Cheap when already
        // installed; otherwise this may take 10-30s on first run.
        do {
            try await downloadService.ensureReady()
        } catch {
            let msg = "NTS station setup failed: \(error.localizedDescription)"
            self.error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        guard let venvPython = downloadService.venvPythonURL,
              let resolverScript = downloadService.ntsResolverScriptURL else {
            let msg = "NTS station: venv python or resolver script path unavailable"
            error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        let resolver: TrackResolver
        do {
            resolver = try TrackResolver(
                venvPython: venvPython,
                wrapperScript: resolverScript
            )
        } catch {
            let msg = "NTS station: resolver init failed: \(error.localizedDescription)"
            self.error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        // Fall back to a fresh empty TasteProfile when the broadcaster
        // wasn't wired up with one (test configs / legacy init). Same
        // degradation story as the Last.fm / Bandcamp sources.
        let profile = tasteProfile ?? TasteProfile()

        // Optional Last.fm client — powers the shared pipeline's
        // stage-5 precision check. Without it the NTS controller
        // still filters via MB era/region + taste scoring, but
        // `artist.getTopTags` verification is skipped (fail-open).
        let lastFM = lastFMClientIfAvailable()

        let controller = NTSStationController(
            config: config,
            nts: nts,
            musicBrainz: musicBrainz,
            lastFM: lastFM,
            history: history,
            resolver: resolver,
            tasteProfile: profile,
            selectionPolicy: selectionPolicyProvider()
        )
        return NTSSource(controller: controller)
    }

    /// Shared helper returning a ``LastFMClient`` when the user has
    /// pasted an API key, or nil otherwise. Used by both
    /// ``makeLastFMSource(config:)`` (where nil is fatal — Last.fm
    /// stations need the key to seed their pool) and
    /// ``makeNTSSource(config:)`` (where nil just skips the optional
    /// precision verification stage). Reads preferences each call so a
    /// freshly-pasted key takes effect on the next broadcast start.
    private func lastFMClientIfAvailable() -> LastFMClient? {
        let apiKey = preferences.lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }
        return LastFMClient(apiKey: apiKey)
    }

    /// Resolve a ``LastFMSource`` from injected dependencies + the user's
    /// Last.fm API key (read from preferences each time so key changes
    /// take effect on the next broadcast start without reconstructing the
    /// broadcaster). Shares the venv + resolver bootstrap path with the
    /// NTS source.
    private func makeLastFMSource(config: LastFMStationConfig) async -> LastFMSource? {
        guard let downloadService, let history else {
            let msg = "Last.fm station requires downloadService + history — none injected"
            error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        guard let client = lastFMClientIfAvailable() else {
            let msg = "Last.fm station: API key missing. Paste one in Settings → Last.fm API key."
            error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        do {
            try await downloadService.ensureReady()
        } catch {
            let msg = "Last.fm station setup failed: \(error.localizedDescription)"
            self.error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        guard let venvPython = downloadService.venvPythonURL,
              let resolverScript = downloadService.ntsResolverScriptURL else {
            let msg = "Last.fm station: venv python or resolver script path unavailable"
            error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        let resolver: TrackResolver
        do {
            resolver = try TrackResolver(
                venvPython: venvPython,
                wrapperScript: resolverScript
            )
        } catch {
            let msg = "Last.fm station: resolver init failed: \(error.localizedDescription)"
            self.error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        // Fall back to a fresh empty TasteProfile when the broadcaster
        // wasn't wired up with one (test configs / legacy init). Scoring
        // against an empty profile just yields zero weights — the pool
        // still narrows via filters, it just loses the "you'd probably
        // like this" boost.
        let profile = tasteProfile ?? TasteProfile()
        // Shared MusicBrainz client — its in-memory caches matter and
        // MB's 1 req/sec budget is per-process, not per-client. The UA
        // string is baked into the eager init so MB's abuse-tracking
        // sees one consistent actor across every station in the app.
        let controller = LastFMStationController(
            config: config,
            client: client,
            musicBrainz: musicBrainz,
            history: history,
            resolver: resolver,
            tasteProfile: profile,
            selectionPolicy: selectionPolicyProvider(),
            seedOverride: seedOverrideProvider(stationID: config.id)
        )
        return LastFMSource(controller: controller)
    }

    /// Resolve a ``BandcampSource`` from injected dependencies. Mirrors
    /// ``makeLastFMSource(config:)`` minus the API-key gate — Bandcamp's
    /// discover endpoint doesn't require auth. The venv + resolver
    /// bootstrap path is identical; the lazy ``BandcampClient`` and
    /// ``MusicBrainzClient`` slots are shared across every subsequent
    /// Bandcamp / Last.fm station so their request-throttle gates and
    /// per-artist caches accumulate instead of resetting per station.
    private func makeBandcampSource(config: BandcampStationConfig) async -> BandcampSource? {
        guard let downloadService, let history else {
            let msg = "Bandcamp station requires downloadService + history — none injected"
            error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        do {
            try await downloadService.ensureReady()
        } catch {
            let msg = "Bandcamp station setup failed: \(error.localizedDescription)"
            self.error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        guard let venvPython = downloadService.venvPythonURL,
              let resolverScript = downloadService.ntsResolverScriptURL else {
            let msg = "Bandcamp station: venv python or resolver script path unavailable"
            error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        let resolver: TrackResolver
        do {
            resolver = try TrackResolver(
                venvPython: venvPython,
                wrapperScript: resolverScript
            )
        } catch {
            let msg = "Bandcamp station: resolver init failed: \(error.localizedDescription)"
            self.error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        // Fall back to a fresh empty TasteProfile when the broadcaster
        // wasn't wired up with one (test configs / legacy init). Same
        // degradation story as ``makeLastFMSource``.
        let profile = tasteProfile ?? TasteProfile()

        // Shared MusicBrainz + Bandcamp clients — the per-artist cache
        // and request-throttle gate carry across station types. Both
        // are constructed at broadcaster init (network-free
        // constructors), so every station sees the same actor instance.
        let controller = BandcampStationController(
            config: config,
            client: bandcamp,
            musicBrainz: musicBrainz,
            history: history,
            resolver: resolver,
            tasteProfile: profile,
            selectionPolicy: selectionPolicyProvider()
        )
        return BandcampSource(controller: controller)
    }

    /// Resolve a ``LibraryRadioStationController`` + ``LibraryRadioSource``.
    /// Synchronous and dependency-light on purpose — the pool is the
    /// owner's own indexed library, so unlike the other generative kinds
    /// there is no venv to bootstrap, no API key to check and no resolver
    /// to construct. The only hard requirement is the library seam;
    /// history and taste profile degrade gracefully exactly as they do
    /// for the sibling factories (empty profile → near-random ranking,
    /// no history → no play recording, no behavioral scoring).
    private func makeLibraryRadioSource(config: LibraryRadioStationConfig) -> LibraryRadioSource? {
        guard let libraryTracks else {
            let msg = "Library Radio station requires the library seam — no music folder loaded yet"
            error = msg
            logger.error("\(msg, privacy: .public)")
            return nil
        }

        let profile = tasteProfile ?? TasteProfile()
        let stationID = config.id

        // The same two closure recorders the playlist branch builds, and
        // for the same reason: the store is macOS-only, the actors are
        // not, and `.map`-returning-closure trips the known inference bug.
        let recorder: (@Sendable (String, String, URL) async -> Int64?)?
        let exclusionRecorder: (@Sendable ([SelectionExclusionRecord]) async -> Void)?
        if let store = history {
            recorder = { (artist: String, title: String, url: URL) async -> Int64? in
                try? await store.record(
                    station: stationID,
                    artist: artist,
                    title: title,
                    cachedPath: url.path
                )
            }
            exclusionRecorder = { (rows: [SelectionExclusionRecord]) async -> Void in
                try? await store.recordExclusions(
                    rows.map(HistoryStore.ExclusionInput.init),
                    stationID: stationID
                )
            }
        } else {
            recorder = nil
            exclusionRecorder = nil
        }

        let controller = LibraryRadioStationController(
            config: config,
            libraryTracks: { await MainActor.run { libraryTracks() } },
            history: history,
            tasteProfile: profile,
            selectionPolicy: selectionPolicyProvider(),
            recordExclusions: exclusionRecorder
        )
        return LibraryRadioSource(controller: controller, recordPlay: recorder)
    }
    #endif

    /// Start broadcasting `station`, pulling successive tracks from an
    /// arbitrary ``TrackSource``. Spins up the encode loop and (if not
    /// already running) the shared HTTP listener + Cloudflare tunnel.
    /// No-op if the station is already live.
    ///
    /// When `source.nextURL()` returns nil the encode loop logs it and
    /// unwinds the pipeline cleanly (as if the user had called
    /// ``stopBroadcast(stationID:)``). Live listeners drop; the caller
    /// can start the station again with a fresh source.
    public func startBroadcast(station: Station, source: TrackSource) async {
        guard !broadcasting.contains(station.id) else { return }
        error = nil

        // A failed-but-non-nil listener must be recreated, not trusted.
        // The control plane has to survive zero stations, so the rebind
        // loop no longer assumes "no pipelines, no listener worth having"
        // — and by the same token a desktop start can arrive while the
        // socket sits dead between rebind attempts. Treating that socket
        // as "already up" would start the station with no way to hear it.
        if let existing = listener {
            switch existing.state {
            case .failed, .cancelled:
                existing.cancel()
                listener = nil
            default:
                break
            }
        }
        // Bring up the shared listener the first time anyone broadcasts.
        if listener == nil {
            do {
                try startHTTPServer()
            } catch {
                self.error = "Listener failed to start: \(error.localizedDescription)"
                logger.error("listener start failed: \(String(describing: error), privacy: .public)")
                return
            }
        }

        // Snapshot prefs at start time so mid-stream changes don't
        // silently corrupt a running encoder. The values ride along with
        // the pipeline; a restart is required to pick up new settings.
        let bitrate = preferences.quality.bitrate
        let sampleRate = Double(preferences.sampleRate.rawValue)

        let pipeline = BroadcastPipeline(
            station: station,
            // The ring has to hold the encoder's whole lead — `pace()`
            // writes up to `broadcastLeadSeconds` past the playout head,
            // and that audio lives here until a listener drains it — plus
            // as much again as margin for a reader whose socket stalls.
            // Sized against the real bitrate, because the old fixed 128KB
            // was under the lead itself at this station's 256 kbps.
            buffer: AACRingBuffer(
                bitrate: bitrate,
                seconds: Self.broadcastLeadSeconds * 2
            ),
            bitrate: bitrate,
            sampleRate: sampleRate,
            source: source
        )
        pipelines[station.id] = pipeline
        let pipelineToken = pipeline.token
        // A station we are broadcasting is one we can always name, even if
        // nobody registered the catalogue (older callers, tests).
        stationNames[station.id] = station.name
        stationSlugs[station.id] = station.slug
        broadcasting.insert(station.id)
        listenerCount[station.id] = 0
        // Restart resilience: remember what's live so the next launch can
        // resume where it was, not just what's auto-start-flagged.
        preferences.rememberLive(slug: station.slug)

        let buffer = pipeline.buffer
        let stationID = station.id
        let stationName = station.name
        // Play-through recording needs HistoryStore, which is macOS-only.
        // Hand the encode loop a platform-neutral closure rather than the
        // store itself so its signature stays cross-platform; on iOS the
        // signal is simply never recorded. Keeping this a closure (instead
        // of routing through `owner`) preserves the direct actor hop — the
        // reason the store was captured here in the first place.
        let recordPlayThrough: (@Sendable (Int64) async -> Void)?
        #if os(macOS)
        if let store = self.history {
            recordPlayThrough = { (id: Int64) async in
                _ = try? await store.incrementPlayCount(id: id)
            }
        } else {
            recordPlayThrough = nil
        }
        #else
        recordPlayThrough = nil
        #endif
        pipeline.encodeTask = Task.detached { [weak self, buffer, recordPlayThrough] in
            await Self.runEncodeLoop(
                source: source,
                stationID: stationID,
                stationName: stationName,
                buffer: buffer,
                bitrate: bitrate,
                sampleRate: sampleRate,
                recordPlayThrough: recordPlayThrough,
                pipelineToken: pipelineToken,
                owner: self
            )
        }

        #if os(macOS)
        // Prime "what just played" from the durable history so the field
        // means something the instant a station goes live. Without this
        // it stayed `[]` until the SECOND track change of the session —
        // which, with the data-conscious idle holding the loop after track
        // one, meant "until somebody tuned in", i.e. usually never.
        seedRecentFromHistory(station: station)
        #endif

        #if os(macOS)
        // First-station bootstrap for the tunnel. `CloudflareTunnel.start`
        // is idempotent, but gating on count avoids spurious log churn.
        startHeartbeatIfNeeded()

        if broadcasting.count == 1, publishesPublicly {
            let tunnelPort = port.rawValue
            Task { [weak self] in
                await self?.tunnel.start(forwardingTo: tunnelPort)
            }
        }
        #endif

        logger.info(
            "station broadcast started: \(station.slug, privacy: .public) on port \(self.port.rawValue, privacy: .public)"
        )
        // Every start — web, desktop, launch resume — is a station-set
        // change the web should hear about without polling.
        pushStationsSSE()
    }

    /// Take a station off air and put it straight back on with the value
    /// supplied — the "remake it" half of editing a station's tags.
    ///
    /// A generative station's pool, controller and dedup state are built
    /// once, at ``startBroadcast(station:)``, from the config. Editing the
    /// config therefore changes nothing anyone can hear until the pipeline
    /// is rebuilt. This is the named, deliberate way to do that, rather
    /// than the UI reaching for stop-then-start and hoping the two halves
    /// stay in step.
    ///
    /// The interruption is real and audible: the current track ends
    /// immediately and listeners reconnect. Callers are expected to say so
    /// before calling. What it is NOT is the owner turning the station off
    /// — the "was live when we last ran" record survives, so a restart can
    /// never cost the station its place in the next launch's resume set.
    ///
    /// Starting an idle station is a valid use: the edit sheet saves the
    /// same way whether or not the station happens to be on air.
    public func restartBroadcast(station: Station) async {
        let wasLive = broadcasting.contains(station.id)
        if wasLive {
            logger.info(
                "restarting \(station.slug, privacy: .public) to pick up an edited config"
            )
            stopBroadcast(stationID: station.id, forgetLive: false)
        }
        await startBroadcast(station: station)
    }

    /// Stop a single station's broadcast. Tears down its encode loop,
    /// disconnects clients bound to it, and drops the pipeline. If it was
    /// the last live station, the shared listener and tunnel come down too.
    public func stopBroadcast(stationID: Station.ID) {
        stopBroadcast(stationID: stationID, forgetLive: true)
    }

    /// Teardown for a pipeline whose encode loop ended on its own — the
    /// source ran dry, or hit an error it could not continue past.
    ///
    /// Distinct from ``stopBroadcast(stationID:)`` in exactly one way: it
    /// keeps the station's "was live" record, so the next launch resumes it.
    /// Running dry is a supply problem, not the owner's decision, and the two
    /// must not look the same after a restart. Exists as a named seam rather
    /// than an inline `forgetLive: false` so the distinction is testable.
    func stopBroadcastRanDry(stationID: Station.ID) {
        stopBroadcast(stationID: stationID, forgetLive: false)
    }

    /// `forgetLive: false` is the shutdown path — ``stopAll()`` tears
    /// pipelines down without erasing the "was live" record, so the next
    /// launch resumes them. A user stopping ONE station is intent; an app
    /// stopping ALL of them is lifecycle. A station that runs dry is
    /// lifecycle too, not intent: the encode loop's own unwind goes through
    /// ``stopBroadcastRanDry(stationID:)`` so starvation cannot quietly
    /// delete a station.
    /// - Parameter tearDownIfEmpty: whether losing the last station should
    ///   also close the shared listener and the tunnel. Only the explicit
    ///   shutdown gesture (``stopAll()``) passes `true`.
    ///
    ///   The tunnel's lifetime used to be coupled to `broadcasting.count`,
    ///   so pool exhaustion, a source error or an ordinary station switch
    ///   took the whole public hostname down and every listener got a
    ///   Cloudflare origin error until someone noticed. Keeping the
    ///   endpoint up to serve 404 is strictly better: the name still
    ///   resolves, the failure is legible to a health check, and a station
    ///   switch is invisible to listeners.
    private func stopBroadcast(
        stationID: Station.ID,
        forgetLive: Bool,
        tearDownIfEmpty: Bool = false
    ) {
        guard let pipeline = pipelines[stationID] else { return }
        if forgetLive {
            preferences.forgetLive(slug: pipeline.station.slug)
        }

        pipeline.encodeTask?.cancel()
        // Free anything parked on this station, or its encode task stays
        // suspended forever.
        signalListenerArrived(stationID: stationID)
        pipelines.removeValue(forKey: stationID)
        broadcasting.remove(stationID)
        listenerCount.removeValue(forKey: stationID)
        currentItemByStation.removeValue(forKey: stationID)
        currentItemStartedAt.removeValue(forKey: stationID)
        upcomingByStation.removeValue(forKey: stationID)
        recentByStation.removeValue(forKey: stationID)

        // Boot any clients still attached to this station.
        let toRemove = clients.filter { $0.value.stationID == stationID }
        for (id, entry) in toRemove {
            clientTasks[id]?.cancel()
            clientTasks.removeValue(forKey: id)
            entry.connection.cancel()
            clients.removeValue(forKey: id)
        }

        if broadcasting.isEmpty, tearDownIfEmpty {
            tearDownListener()
        }

        logger.info("station broadcast stopped: \(pipeline.station.slug, privacy: .public)")
        // One push point covers every way a station leaves the air —
        // owner stop, restart, ran-dry, delete — because they all funnel
        // through here.
        pushStationsSSE()
    }

    /// Stop every running broadcast and tear the listener down. Idempotent.
    /// Keeps the last-live record intact — this is the shutdown/restart-all
    /// gesture, and the next launch should resume what was playing.
    public func stopAll() {
        for id in Array(pipelines.keys) {
            stopBroadcast(stationID: id, forgetLive: false, tearDownIfEmpty: true)
        }
        // Idempotent, and covers the case where there were no pipelines
        // left to iterate but the listener/tunnel were still up.
        tearDownListener()
        // A full stop resets the "needs restart" banner — the next start
        // will pick up current preferences as its fresh baseline.
        needsRestart = false
    }

    /// Whether `stationID` is currently broadcasting.
    public func isBroadcasting(stationID: Station.ID) -> Bool {
        broadcasting.contains(stationID)
    }

    /// Tell the broadcaster about the user's full station catalogue.
    ///
    /// Two things depend on it, and both were broken without it:
    ///
    /// 1. `/history` could only name a station that happened to be
    ///    broadcasting right then, so every row belonging to an idle
    ///    station came back with an empty name. The catalogue covers idle
    ///    stations too.
    /// 2. A live pipeline held a `Station` value frozen at broadcast start,
    ///    so renaming a station left `/now.json` and `/history` publishing
    ///    the old name until the next restart.
    ///
    /// Call it whenever the saved list changes — creation, rename, edit,
    /// delete — and once after loading it from disk. It is a pure
    /// bookkeeping update: it never starts, stops or restarts anything, and
    /// stations it doesn't mention are left exactly as they are.
    public func registerStations(_ stations: [Station]) {
        // A *desktop-side* create/rename/edit/delete reaches web clients
        // through this call (RootView re-registers on every catalogue
        // change), so an actual change gets an SSE nudge. Compared
        // against the previous registration, not `stationNames` — that
        // map deliberately keeps deleted stations (so /history can still
        // name them), which would hide exactly the deletes we're after.
        let changed = lastRegisteredStations != stations
        lastRegisteredStations = stations
        for station in stations {
            stationNames[station.id] = station.name
            stationSlugs[station.id] = station.slug
        }
        // A live pipeline's copy is what the wire reads, so refresh it.
        for station in stations {
            guard let pipeline = pipelines[station.id] else { continue }
            let previousSlug = pipeline.station.slug
            pipeline.station = station
            // The slug is derived from the name, so a rename moves the
            // station's stream path. The "was live when we last ran"
            // record is keyed by slug — leaving the old one behind would
            // make the next launch try to resume a path that no longer
            // answers.
            if previousSlug != station.slug {
                preferences.forgetLive(slug: previousSlug)
                preferences.rememberLive(slug: station.slug)
                logger.info(
                    "station renamed while live: \(previousSlug, privacy: .public) → \(station.slug, privacy: .public)"
                )
            }
        }
        if changed {
            pushStationsSSE()
        }
        objectWillChange.send()
    }

    #if os(macOS)
    /// User hit 👎 on the currently-playing track. Marks it as skipped
    /// in history (so the taste profile's blacklist will suppress it on
    /// this station) and nudges the encode loop to drop the current
    /// track. The next track resolves through the normal pool pipeline,
    /// which honors the fresh skip via its pre-scoring filter.
    ///
    /// No-op when the station isn't live, has no currently-playing
    /// item, or the item lacks a historyID (playlist-backed stations).
    public func skipCurrent(stationID: Station.ID) async {
        guard pipelines[stationID] != nil else { return }
        guard let item = currentItemByStation[stationID] else { return }
        guard let historyID = item.historyID else { return }

        if let history {
            do {
                try await history.markSkipped(id: historyID)
                logger.info("👎 skip recorded: \(item.artist ?? "?", privacy: .public) — \(item.title ?? "?", privacy: .public)")
            } catch {
                logger.error("skip mark failed: \(String(describing: error), privacy: .public)")
            }
        }
        // Nudge the encode loop. The inner PCM loop reads this flag on
        // each iteration and breaks out, which advances the outer loop
        // to the next item; the loop also marks a ring-buffer
        // discontinuity so listeners skip the stale backlog.
        pipelines[stationID]?.skipRequested = true
    }
    #endif

    /// Local stream URL for `station`, or `nil` if it isn't broadcasting.
    /// Shape: `http://localhost:{port}/stream/{slug}.aac` — aligned with
    /// the path-based routing the shared listener implements.
    public func streamURL(for station: Station) -> URL? {
        guard broadcasting.contains(station.id) else { return nil }
        return URL(string: "http://localhost:\(port.rawValue)/stream/\(station.slug).aac")
    }

    /// Tear the shared listener down and drop all client tracking. Called
    /// when the last broadcast stops — keeping the listener up with no
    /// pipelines would serve 404s to all comers, which is accurate but
    /// wasteful.
    private func tearDownListener() {
        stopHeartbeat()
        listenerRebindTask?.cancel()
        listenerRebindTask = nil
        listenerRebindAttempt = 0
        #if os(macOS)
        tunnel.stop()
        #endif

        for (_, task) in clientTasks { task.cancel() }
        clientTasks.removeAll()
        for (_, entry) in clients { entry.connection.cancel() }
        clients.removeAll()
        for (_, conn) in sseSubscribers { conn.cancel() }
        sseSubscribers.removeAll()

        listener?.cancel()
        listener = nil
    }

    /// Called from the detached encode loop each time the decoder opens a
    /// new track. Drives the ICY metadata surfaced to clients at the next
    /// block boundary.
    ///
    /// `artwork` is the outgoing file's embedded cover art, already read off
    /// the detached loop (see ``TrackFileProbe``). Provenance used to be
    /// resolved here with a per-track hop back into ``HistoryStore``; the
    /// sources now carry it on the item itself, which removes both the hop
    /// and the window where `/now.json` showed a track with no source URL
    /// because the lookup hadn't landed yet.
    fileprivate func updateCurrentItem(
        _ item: TrackSourceItem?,
        artwork: Data? = nil,
        measuredDuration: TimeInterval? = nil,
        stationID: Station.ID
    ) {
        // Retire the outgoing track into the recent ring. Newest first.
        if let outgoing = currentItemByStation[stationID] {
            var ring = recentByStation[stationID] ?? []
            ring.insert(RecentTrack(
                entryID: UUID(), item: outgoing, playedAt: Date()
            ), at: 0)
            if ring.count > Self.recentRingCapacity {
                ring.removeLast(ring.count - Self.recentRingCapacity)
            }
            recentByStation[stationID] = ring
        }
        // The prefetched "next" either just became current or was skipped
        // past — either way it's stale until the loop re-publishes.
        upcomingByStation.removeValue(forKey: stationID)
        if let item {
            var probedArtwork: String?
            if let artwork {
                let id = TrackFileProbe.artworkID(for: item.url)
                cacheArtwork(artwork, id: id)
                probedArtwork = "/artwork/\(id).jpg"
            }
            currentItemByStation[stationID] = item.withProbedFile(
                artworkURL: probedArtwork, duration: measuredDuration
            )
            currentItemStartedAt[stationID] = Date()
        } else {
            currentItemByStation.removeValue(forKey: stationID)
            currentItemStartedAt.removeValue(forKey: stationID)
        }
        // A track change is exactly what /events subscribers are waiting
        // for — push the fresh now-playing snapshot.
        pushSSE()
    }

    #if os(macOS)
    /// Fill a station's recent ring from its newest history rows.
    ///
    /// Runs once per broadcast start, before the first track opens, so the
    /// ring is never empty for a station that has played before. Rows the
    /// in-memory ring will re-add naturally are harmless — a retiring track
    /// pushes onto the front and the cap trims the tail.
    ///
    /// A row is only usable if its `cachedPath` still exists: the recent
    /// entries double as retro-♥ targets, and offering a ♥ for a file the
    /// LRU already evicted would be a button that can only fail. Rows
    /// without a live file are skipped, which is why the ring can come back
    /// shorter than the capacity.
    private func seedRecentFromHistory(station: Station) {
        let stationID = station.id
        guard let history, recentByStation[stationID] == nil else { return }
        let capacity = Self.recentRingCapacity
        let musicFolder = libraryConfig?.musicFolder
        // History rows don't record which controller produced them, but the
        // station being started does — its kind is the same for every row
        // it ever wrote.
        let origin: TrackOrigin
        switch station.kind {
        case .playlist: origin = .library
        case .nts: origin = .nts
        case .lastFM: origin = .lastFM
        case .bandcamp: origin = .bandcamp
        // Library Radio plays the owner's own files — the same truth
        // `.playlist` tells the wire.
        case .libraryRadio: origin = .library
        }
        Task { [weak self] in
            let rows = (try? await history.recentEntries(
                forStation: stationID, limit: capacity
            )) ?? []
            let seeded: [RecentTrack] = rows.compactMap { row in
                guard let path = row.cachedPath,
                      FileManager.default.fileExists(atPath: path) else { return nil }
                let url = URL(fileURLWithPath: path)
                let owned = musicFolder.map { url.path.hasPrefix($0.path) } ?? false
                return RecentTrack(
                    entryID: UUID(),
                    item: TrackSourceItem(
                        url: url,
                        artist: row.artist,
                        title: row.title,
                        sourceURL: row.sourceShowURL?.absoluteString,
                        youtubeURL: TrackSourceItem.youtubeWatchURL(for: row.youtubeID),
                        origin: origin,
                        // A ♥ on a seeded row must take the same path it
                        // would have taken live: owned files record affinity
                        // (no row id needed), cached ones copy the file.
                        historyID: owned ? nil : row.id,
                        isOwned: owned
                    ),
                    playedAt: row.playedAt
                )
            }
            guard !seeded.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.pipelines[stationID] != nil else { return }
                var ring = self.recentByStation[stationID] ?? []
                // Anything the live ring already retired wins — it is newer.
                ring.append(contentsOf: seeded)
                if ring.count > capacity { ring.removeLast(ring.count - capacity) }
                self.recentByStation[stationID] = ring
                self.pushSSE()
            }
        }
    }
    #endif

    /// Store cover-art bytes under `id`, evicting the oldest once the cache
    /// is over its limit. Insertion-ordered rather than true LRU: the access
    /// pattern is "the current track, then whatever is in the recent ring",
    /// which insertion order already tracks.
    private func cacheArtwork(_ data: Data, id: String) {
        if artworkCache[id] == nil {
            artworkOrder.append(id)
        }
        artworkCache[id] = data
        while artworkOrder.count > Self.artworkCacheLimit {
            let evicted = artworkOrder.removeFirst()
            artworkCache.removeValue(forKey: evicted)
        }
    }

    /// Cover-art bytes for `id`, or nil if we never had them / they aged out.
    func artwork(id: String) -> Data? { artworkCache[id] }

    /// The encode loop's prefetch resolved — publish it as the certain
    /// next track. Only meaningful while its station still broadcasts.
    fileprivate func updateUpcoming(_ item: TrackSourceItem, stationID: Station.ID) {
        guard pipelines[stationID] != nil else { return }
        upcomingByStation[stationID] = item
        pushSSE()
    }

    /// Snapshot of the current item for a detached serve loop. Lets a
    /// client task ask "what's playing for MY station?" without grabbing
    /// the whole actor state.
    fileprivate func snapshotCurrentItem(stationID: Station.ID) -> TrackSourceItem? {
        currentItemByStation[stationID]
    }

    /// Detached encode loop uses this to read+clear the per-pipeline
    /// skip flag once per PCM iteration. Returns `true` iff a skip was
    /// requested; the loop then breaks out of the current track's inner
    /// loop so the outer loop advances to the next item.
    fileprivate func consumeSkipRequest(stationID: Station.ID) -> Bool {
        guard let pipeline = pipelines[stationID] else { return false }
        let was = pipeline.skipRequested
        pipeline.skipRequested = false
        return was
    }

    // MARK: - HTTP server

    /// Delay before rebind attempt `attempt` (1-based): 0.5s doubling to a
    /// 30s cap. Same shape as the tunnel supervisor's backoff.
    nonisolated public static func listenerRebindDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0.5 }
        return min(30, 0.5 * pow(2, Double(attempt - 1)))
    }

    /// Rebind the shared listener after a failure, with backoff.
    ///
    /// Never escalates to `stopAll()`. A listener that gives up cannot come
    /// back when the conflicting process exits or the interface returns,
    /// and staying off air forever is a worse outcome than retrying — the
    /// same reasoning as the tunnel supervisor and the open-failure
    /// backoff.
    private func scheduleListenerRebind(reason: String) {
        // Deliberately NOT gated on `pipelines.isEmpty`. The listener is
        // the control plane, not just the audio plane: /now.json, /health
        // and (soon) /stations/* must answer at zero stations, because a
        // dead socket with nothing broadcasting is exactly the state a
        // remote owner needs the socket to escape from — stop the last
        // station over the web and the "nothing to serve" guard would
        // have made starting one again impossible.
        //
        // One rebind in flight at a time.
        guard listenerRebindTask == nil else { return }

        listenerRebindAttempt += 1
        let delay = Self.listenerRebindDelay(forAttempt: listenerRebindAttempt)
        logger.error(
            "listener \(reason, privacy: .public); rebinding in \(delay, privacy: .public)s (attempt \(self.listenerRebindAttempt, privacy: .public))"
        )

        listenerRebindTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.listenerRebindTask = nil
                self.listener?.cancel()
                self.listener = nil
                do {
                    try self.startHTTPServer()
                } catch {
                    self.logger.error(
                        "listener rebind threw: \(String(describing: error), privacy: .public)"
                    )
                    self.scheduleListenerRebind(reason: "rebind threw")
                }
            }
        }
    }

    private func startHTTPServer() throws {
        let params = NWParameters.tcp
        // Allow re-binding immediately on restart instead of waiting for
        // the OS's TIME_WAIT timeout.
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.listenerRebindAttempt = 0
                    self.error = nil
                    self.logger.notice(
                        "listener ready on port \(self.port.rawValue, privacy: .public)"
                    )
                case .failed(let err):
                    // Was `stopAll()`: a single transient bind problem took
                    // every station off air with no retry and no rebind —
                    // and since stopAll also drops the tunnel, the public
                    // hostname went with it, permanently.
                    self.error = "Listener failed: \(err.localizedDescription)"
                    self.logger.error("listener failed: \(String(describing: err), privacy: .public)")
                    self.scheduleListenerRebind(reason: "failed")
                case .waiting(let err):
                    // `.waiting` is where a bind conflict or a lost
                    // interface lands. It used to fall into `default` and
                    // be ignored completely, so the radio sat there
                    // silently un-bound.
                    self.logger.error("listener waiting: \(String(describing: err), privacy: .public)")
                    self.scheduleListenerRebind(reason: "waiting")
                case .cancelled:
                    self.logger.info("listener cancelled")
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in
                self.routeIncoming(connection)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    /// Read the request line, dispatch on path. Everything after the
    /// handshake is pipeline-specific — we just do the path→pipeline lookup
    /// here and hand off.
    private func routeIncoming(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        let pipelineLookup: @Sendable (String) async -> (Station.ID, AACRingBuffer, String)? = { [weak self] slug in
            await MainActor.run { [weak self] in
                guard let self, let pipeline = self.pipelines.first(where: { $0.value.station.slug == slug })?.value else {
                    return nil
                }
                return (pipeline.station.id, pipeline.buffer, pipeline.station.name)
            }
        }
        let legacyRedirectSlug: @Sendable () async -> String? = { [weak self] in
            await MainActor.run { [weak self] in
                self?.pipelines.values.first?.station.slug
            }
        }
        let nowPayload: @Sendable () async -> Data = { [weak self] in
            await MainActor.run { [weak self] in
                self?.buildNowPayload() ?? Data("{\"stations\":[]}".utf8)
            }
        }
        let historyPayload: @Sendable (String) async -> Data = { [weak self] path in
            await self?.buildHistoryPayload(path: path)
                ?? Data("{\"entries\":[]}".utf8)
        }
        let healthPayload: @Sendable () async -> Data = { [weak self] in
            await self?.buildHealthPayload()
                ?? Data("{\"status\":\"error\"}".utf8)
        }
        let trackInfoRoute: @Sendable (String) async -> (Int, Data) = { [weak self] path in
            await self?.performTrackInfoAsync(path: path)
                ?? (500, Data("{\"status\":\"error\",\"message\":\"no broadcaster\"}".utf8))
        }
        let jsonRoute: @Sendable (String, Data) async -> (Int, Data) = { [weak self] path, body in
            // Hop to the main actor exactly once per request; the
            // per-route semantics live in `performJSONRoute`. One closure
            // instead of one per route — the old shape allocated six of
            // them per connection, including for plain GET /now.json polls.
            await self?.performJSONRoute(path: path, body: body)
                ?? (500, Data("{\"status\":\"error\",\"message\":\"no broadcaster\"}".utf8))
        }

        let task = Task.detached { [weak self] in
            // Read headers to learn both the request path and whether the
            // client wants ICY metadata — two pieces of information from
            // the same read.
            let headerBytes = await Self.readUntilHeaderEnd(connection: connection)
            let path = Self.requestPath(from: headerBytes) ?? "/stream.aac"
            let method = Self.requestMethod(from: headerBytes) ?? "GET"
            let wantsMetadata = Self.headerRequestsICYMetadata(headerBytes)

            // CORS preflight for the action POSTs — browsers send OPTIONS
            // before the real POST because we use Content-Type: application/json.
            // Gated on the same Set as the dispatch below, so a route can't
            // exist for one and not the other.
            if method == "OPTIONS" && Self.jsonPostPaths.contains(path) {
                _ = await Self.send(
                    data: Self.buildHTTPResponse(
                        status: 204,
                        headers: Self.corsHeaders(),
                        body: Data()
                    ),
                    on: connection
                )
                connection.cancel()
                return
            }

            // Every JSON action POST funnels through one shape: bound and
            // read the body, hop to the main actor to route, answer with
            // CORS + JSON. The per-route semantics — including the 400 for
            // a body that doesn't decode — live in `performJSONRoute`.
            if method == "POST", Self.jsonPostPaths.contains(path) {
                let contentLength = Self.contentLength(from: headerBytes) ?? 0
                guard contentLength <= Self.maxJSONBodyBytes else {
                    // Refuse outright rather than truncating into an opaque
                    // decode failure. Drain what the client is mid-sending
                    // first: closing with unread bytes in the receive
                    // buffer makes the OS RST the connection, which can
                    // destroy the very response we're trying to deliver.
                    _ = await Self.readBody(
                        connection: connection,
                        alreadyRead: Self.bodyBytes(after: headerBytes),
                        expected: contentLength
                    )
                    var headers = Self.corsHeaders()
                    headers["Content-Type"] = "application/json"
                    _ = await Self.send(
                        data: Self.buildHTTPResponse(
                            status: 413,
                            headers: headers,
                            body: Data("{\"status\":\"error\",\"message\":\"body too large\"}".utf8)
                        ),
                        on: connection
                    )
                    connection.cancel()
                    return
                }
                let body = await Self.readBody(
                    connection: connection,
                    alreadyRead: Self.bodyBytes(after: headerBytes),
                    expected: contentLength,
                    timeout: Self.jsonBodyReadTimeout
                )
                let (status, payload) = await jsonRoute(path, body)
                var headers = Self.corsHeaders()
                headers["Content-Type"] = "application/json"
                _ = await Self.send(
                    data: Self.buildHTTPResponse(status: status, headers: headers, body: payload),
                    on: connection
                )
                connection.cancel()
                return
            }

            // Persistent play history — the DB-backed counterpart of the
            // in-memory `recent` ring in /now.json. Survives restarts and
            // reaches back as far as the store does. Public read, same
            // posture as /now.json: it only exposes what was broadcast.
            // Exact path (plus optional query) — a bare `hasPrefix` also
            // claimed /historyanything, which should 404 like any other
            // unknown path.
            if path == "/history" || path.hasPrefix("/history?") {
                let payload = await historyPayload(path)
                _ = await Self.send(
                    data: Self.buildHTTPResponse(
                        status: 200,
                        headers: [
                            "Content-Type": "application/json",
                            "Access-Control-Allow-Origin": "*",
                            "Cache-Control": "no-cache"
                        ],
                        body: payload
                    ),
                    on: connection
                )
                connection.cancel()
                return
            }

            // "About this track" — enrichment for a station's current (or
            // still-in-the-ring recent) track. Same exact-path-plus-query
            // match as /history, and the same public-read posture: it only
            // answers for tracks the station is (or just was)
            // broadcasting, so it can't be driven as an open Last.fm
            // proxy. Status varies (404 for "nothing to describe"), which
            // is why this route carries one, unlike its GET neighbours.
            if path == "/trackinfo" || path.hasPrefix("/trackinfo?") {
                let (status, payload) = await trackInfoRoute(path)
                _ = await Self.send(
                    data: Self.buildHTTPResponse(
                        status: status,
                        headers: [
                            "Content-Type": "application/json",
                            "Access-Control-Allow-Origin": "*",
                            "Cache-Control": "no-cache"
                        ],
                        body: payload
                    ),
                    on: connection
                )
                connection.cancel()
                return
            }

            // Cover art extracted from a local file's own tags. Generative
            // tracks point `artworkURL` straight at the source's CDN, so
            // this route only ever serves library art — bytes we already
            // hold in memory for the current track and the recent ring.
            if let artworkID = Self.extractArtworkID(from: path) {
                let bytes = await MainActor.run { [weak self] in
                    self?.artwork(id: artworkID)
                }
                guard let bytes else {
                    _ = await Self.send(
                        data: Data(Self.notFoundResponse().utf8), on: connection
                    )
                    connection.cancel()
                    return
                }
                _ = await Self.send(
                    data: Self.buildHTTPResponse(
                        status: 200,
                        headers: [
                            "Content-Type": "image/jpeg",
                            "Access-Control-Allow-Origin": "*",
                            // Content is immutable for a given id (it is a
                            // digest of the file path), so let clients keep
                            // it rather than re-fetching per poll.
                            "Cache-Control": "public, max-age=86400"
                        ],
                        body: bytes
                    ),
                    on: connection
                )
                connection.cancel()
                return
            }

            // Station-form vocabulary — tag palettes, enum spellings,
            // region codes. Public and cacheable: it is compiled-in
            // constants, nothing about this owner's stations, and an
            // hour of client caching spares the tunnel a request the
            // answer to which changes once per deploy at most.
            if path == "/vocab" {
                _ = await Self.send(
                    data: Self.buildHTTPResponse(
                        status: 200,
                        headers: [
                            "Content-Type": "application/json",
                            "Access-Control-Allow-Origin": "*",
                            "Cache-Control": "public, max-age=3600"
                        ],
                        body: Self.buildVocabPayload()
                    ),
                    on: connection
                )
                connection.cancel()
                return
            }

            // Deploy-verification and capability surface. No auth, same
            // posture as /now.json: it names only stations that have been
            // on air, which were public knowledge while they were. Serves
            // 200 even when degraded — see ``buildHealthPayload()``.
            if path == "/health" {
                let payload = await healthPayload()
                _ = await Self.send(
                    data: Self.buildHTTPResponse(
                        status: 200,
                        headers: [
                            "Content-Type": "application/json",
                            "Access-Control-Allow-Origin": "*",
                            "Cache-Control": "no-cache"
                        ],
                        body: payload
                    ),
                    on: connection
                )
                connection.cancel()
                return
            }

            // Public JSON status. Lists the CURRENTLY BROADCASTING stations
            // plus their current track and listener counts. No auth —
            // broadcaster only knows live stations, so idle library
            // entries can't leak.
            if path == "/now.json" {
                let payload = await nowPayload()
                _ = await Self.send(
                    data: Self.buildHTTPResponse(
                        status: 200,
                        headers: [
                            "Content-Type": "application/json",
                            "Access-Control-Allow-Origin": "*",
                            "Cache-Control": "no-cache"
                        ],
                        body: payload
                    ),
                    on: connection
                )
                connection.cancel()
                return
            }

            // Live now-playing push (Server-Sent Events). Holds the
            // connection open and streams a fresh /now.json snapshot on
            // every track change and listener-count move, so clients that
            // want it can drop polling. A periodic heartbeat keeps idle
            // intermediaries from timing the connection out.
            if path == "/events" {
                let sseHeader = """
                HTTP/1.1 200 OK\r
                Content-Type: text/event-stream\r
                Cache-Control: no-cache\r
                Connection: keep-alive\r
                Access-Control-Allow-Origin: *\r
                \r

                """
                guard await Self.send(data: Data(sseHeader.utf8), on: connection) else {
                    connection.cancel()
                    return
                }
                await MainActor.run { [weak self] in self?.registerSSE(connection) }
                // Initial snapshot so the client renders immediately rather
                // than waiting for the first track change.
                _ = await Self.send(data: Self.sseEvent(await nowPayload(), name: "now"), on: connection)
                // Heartbeat loop. Pushes are driven from the broadcaster;
                // this only keeps the pipe warm and notices a dead peer.
                // A named `ping` rather than a `:` comment frame: comments
                // are invisible to `EventSource`, so the web client's
                // liveness watchdog had to guess at the cadence. An event
                // it can listen for makes "the pipe is warm" exact.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if Task.isCancelled { break }
                    let alive = await Self.send(data: Data("event: ping\ndata: {}\n\n".utf8), on: connection)
                    if !alive { break }
                }
                await MainActor.run { [weak self] in self?.removeSSE(ObjectIdentifier(connection)) }
                connection.cancel()
                return
            }

            // Legacy endpoint: redirect to the first broadcasting station
            // so existing bookmarks keep working. 404 when nothing's live.
            if path == "/stream.aac" || path == "/stream" {
                if let slug = await legacyRedirectSlug() {
                    _ = await Self.send(
                        data: Data(Self.redirectResponse(slug: slug).utf8),
                        on: connection
                    )
                } else {
                    _ = await Self.send(
                        data: Data(Self.notFoundResponse().utf8),
                        on: connection
                    )
                }
                connection.cancel()
                return
            }

            guard let slug = Self.extractSlug(from: path),
                  let (stationID, buffer, stationName) = await pipelineLookup(slug) else {
                _ = await Self.send(
                    data: Data(Self.notFoundResponse().utf8),
                    on: connection
                )
                connection.cancel()
                return
            }

            await MainActor.run { [weak self] in
                self?.registerClient(connection, stationID: stationID)
            }

            await Self.serveClient(
                connection: connection,
                buffer: buffer,
                stationID: stationID,
                stationName: stationName,
                wantsMetadata: wantsMetadata,
                ownerRef: { [weak self] in self }
            )

            connection.cancel()
            await MainActor.run { [weak self] in
                self?.removeClient(ObjectIdentifier(connection))
            }
        }
        // We key the task under the connection identity so stopBroadcast
        // can cancel in-flight client loops cleanly. The connection isn't
        // registered as a client yet (that happens once we've identified
        // its station), so only keep the task in a transient slot.
        let id = ObjectIdentifier(connection)
        clientTasks[id] = task

        // Reap the slot when the connection goes away.
        //
        // The only removals used to be `removeClient` — which is wired up
        // in `registerClient`, i.e. for stream clients only — and
        // `tearDownListener`. Every /now.json, /history, /events and
        // action POST therefore left its entry behind forever, so the
        // dictionary grew monotonically for the whole broadcast session.
        // `registerClient` replaces this handler for stream clients; that
        // one also clears `clientTasks`, so both paths are covered.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.reapConnectionTask(id)
                }
            default:
                break
            }
        }
    }

    /// Drop a finished connection's task slot. Safe for connections that
    /// were never registered as stream clients.
    private func reapConnectionTask(_ id: ObjectIdentifier) {
        guard clients[id] == nil else { return }  // stream client: removeClient owns it
        clientTasks.removeValue(forKey: id)
    }

    /// How many connection tasks are currently tracked. Test-facing: the
    /// leak this guards against is invisible from outside.
    var trackedConnectionTaskCount: Int { clientTasks.count }

    private func registerClient(_ connection: NWConnection, stationID: Station.ID) {
        let id = ObjectIdentifier(connection)
        clients[id] = (connection, stationID)
        listenerCount[stationID, default: 0] += 1
        // Wake the encode loop now rather than up to 5s later.
        signalListenerArrived(stationID: stationID)
        logger.info(
            "client connected to \(stationID.uuidString.prefix(8), privacy: .public), total \(self.listenerCount[stationID] ?? 0, privacy: .public)"
        )

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    self.removeClient(id)
                }
            default:
                break
            }
        }

        // Listener count changed — let /events subscribers update their
        // "N listening" badge live.
        pushSSE()
    }

    private func removeClient(_ id: ObjectIdentifier) {
        if let entry = clients.removeValue(forKey: id) {
            if let count = listenerCount[entry.stationID], count > 0 {
                listenerCount[entry.stationID] = count - 1
            }
            logger.info(
                "client disconnected, remaining \(self.listenerCount[entry.stationID] ?? 0, privacy: .public)"
            )
            pushSSE()
        }
        clientTasks.removeValue(forKey: id)
    }

    // MARK: - Server-Sent Events

    /// Register a `/events` subscriber and wire its disconnect cleanup.
    private func registerSSE(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        sseSubscribers[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self.removeSSE(id) }
            default:
                break
            }
        }
        logger.info("SSE subscriber connected, total \(self.sseSubscribers.count, privacy: .public)")
    }

    private func removeSSE(_ id: ObjectIdentifier) {
        if sseSubscribers.removeValue(forKey: id) != nil {
            logger.info("SSE subscriber disconnected, remaining \(self.sseSubscribers.count, privacy: .public)")
        }
    }

    /// Push the current now-playing snapshot to every `/events` subscriber.
    /// Fire-and-forget per connection; a failed send drops that subscriber.
    /// Snapshots are last-write-wins, so the rare out-of-order delivery
    /// under rapid changes is harmless.
    private func pushSSE() {
        guard !sseSubscribers.isEmpty else { return }
        let event = Self.sseEvent(buildNowPayload(), name: "now")
        for (id, conn) in sseSubscribers {
            Task { [weak self] in
                let ok = await Self.send(data: event, on: conn)
                if !ok { await MainActor.run { self?.removeSSE(id) } }
            }
        }
    }

    /// Tell every `/events` subscriber the station picture changed —
    /// something started, stopped, or the catalogue itself mutated.
    ///
    /// The body is deliberately an empty object: `/events` is public,
    /// and the owner catalogue must never ride it. The event is a nudge,
    /// not a snapshot — clients re-fetch what they are entitled to
    /// (public `/now.json`, owner `/stations/list`) on receipt.
    /// Relay a transport command to every listening client. The body
    /// carries only what changed, so "mute" does not also reset volume.
    func pushTransportSSE(muted: Bool?, volume: Double?) {
        guard !sseSubscribers.isEmpty else { return }
        var fields: [String] = []
        if let muted { fields.append("\"muted\":\(muted)") }
        if let volume {
            // Clamp here rather than trusting the wire: a slider is a
            // slider, but this endpoint is reachable by anything.
            let v = min(1, max(0, volume))
            fields.append("\"volume\":\(v)")
        }
        guard !fields.isEmpty else { return }
        let event = Self.sseEvent(Data("{\(fields.joined(separator: ","))}".utf8), name: "transport")
        for (id, conn) in sseSubscribers {
            Task { [weak self] in
                let ok = await Self.send(data: event, on: conn)
                if !ok { await MainActor.run { self?.removeSSE(id) } }
            }
        }
    }

    func pushStationsSSE() {
        guard !sseSubscribers.isEmpty else { return }
        let event = Self.sseEvent(Data("{}".utf8), name: "stations")
        for (id, conn) in sseSubscribers {
            Task { [weak self] in
                let ok = await Self.send(data: event, on: conn)
                if !ok { await MainActor.run { self?.removeSSE(id) } }
            }
        }
    }

    /// Frame a JSON payload as a single SSE event. SSE is line-oriented
    /// and terminates an event with a blank line; our payload is
    /// single-line JSON so one `data:` line suffices. `name` becomes an
    /// `event:` line so `EventSource` clients can `addEventListener` on
    /// it — every frame we send is named (`now` for snapshots, `ping` for
    /// the keep-alive), and there are no unnamed-frame consumers to keep
    /// compatible, so new frame kinds should be named too.
    nonisolated static func sseEvent(_ json: Data, name: String? = nil) -> Data {
        var out = Data()
        if let name {
            out.append(Data("event: \(name)\n".utf8))
        }
        out.append(Data("data: ".utf8))
        out.append(json)
        out.append(Data("\n\n".utf8))
        return out
    }

    // MARK: - JSON POST routing

    /// Every JSON POST route. Single source of truth for BOTH the CORS
    /// OPTIONS preflight and the POST dispatch — a path added here gets
    /// both, so a new route can never ship answering POSTs while
    /// stonewalling the preflight browsers send first (or vice versa).
    nonisolated static let jsonPostPaths: Set<String> = [
        "/auth", "/like", "/skip", "/next", "/boost", "/unlike",
        "/stations/list", "/stations/create", "/stations/update",
        "/stations/delete", "/stations/start", "/stations/stop",
        "/stations/autostart",
        "/policy/get", "/policy/set", "/taste", "/exclusions",
        "/transport"
    ]

    /// Ceiling on a JSON POST body. The largest legitimate payload today
    /// is a station config (40 tags + regions + excluded artists), which
    /// is well under a kilobyte — 64 KB is generous headroom, while
    /// anything past it is not a config, it's a hose.
    nonisolated static let maxJSONBodyBytes = 64 * 1024

    /// Wall-clock budget for reading a JSON POST body. The old flat 3s
    /// was tuned for `{"station":…,"token":…}` and silently truncated
    /// larger bodies arriving in dribs over a slow tunnel — which then
    /// failed to decode and surfaced as an opaque 400. Config-sized
    /// payloads get a budget that covers a bad mobile link instead.
    nonisolated static let jsonBodyReadTimeout: TimeInterval = 10

    /// The shared 400 for a body that doesn't decode or a station id that
    /// doesn't parse — the same bytes every route used to assemble inline.
    nonisolated static func badRequest() -> (Int, Data) {
        (400, Data("{\"status\":\"error\",\"message\":\"bad request\"}".utf8))
    }

    /// Route a JSON POST to its handler. One switch instead of five
    /// copy-pasted per-connection blocks; runs on the main actor so each
    /// case can reach broadcaster state directly, with the detached
    /// reader hopping here exactly once per request.
    func performJSONRoute(path: String, body: Data) async -> (Int, Data) {
        let decoder = JSONDecoder()
        switch path {
        case "/auth":
            // Passcode check for the web player's unlock prompt. Answers
            // 200 or 403 and changes nothing either way. A malformed or
            // empty body decodes to "no token" and takes the ordinary
            // rejection path instead of a 400 — see ``AuthRequest``.
            return await performAuthAsync(
                token: (try? decoder.decode(AuthRequest.self, from: body))?.token
            )
        case "/like":
            // ♥ save — move the currently-playing cached file into the
            // user's library. Retro-♥ rides the same route: an `entry` id
            // from the recent ring saves that just-played track instead
            // ("the one that got away, two tracks back").
            guard let req = try? decoder.decode(LikeRequest.self, from: body),
                  let stationID = UUID(uuidString: req.station) else {
                return Self.badRequest()
            }
            if let entry = req.entry {
                return await performRetroLikeAsync(
                    stationID: stationID, entryID: entry, token: req.token
                )
            }
            return await performLikeAsync(stationID: stationID, token: req.token)
        case "/skip":
            // 👎 — mark the current track skipped (taste blacklist) and
            // nudge the encode loop to advance.
            guard let req = try? decoder.decode(LikeRequest.self, from: body),
                  let stationID = UUID(uuidString: req.station) else {
                return Self.badRequest()
            }
            return await performSkipAsync(stationID: stationID, token: req.token)
        case "/next":
            // ⏭ — advance without judging. No taste signal, no history
            // mark; "not right now" mustn't poison the profile the way
            // 👎 deliberately does.
            guard let req = try? decoder.decode(LikeRequest.self, from: body),
                  let stationID = UUID(uuidString: req.station) else {
                return Self.badRequest()
            }
            return await performNextAsync(stationID: stationID, token: req.token)
        case "/boost":
            // Boost — "more of this": the strong steering signal, above ♥.
            guard let req = try? decoder.decode(LikeRequest.self, from: body),
                  let stationID = UUID(uuidString: req.station) else {
                return Self.badRequest()
            }
            return await performBoostAsync(stationID: stationID, token: req.token)
        case "/transport":
            // The remote control. Volume lives in each browser, so one of
            // the owner's browsers cannot reach another's speaker on its
            // own — the broadcaster relays the keypress and every owner
            // browser applies it. Deliberately NOT stored: this is a
            // press, not a setting, so a browser that joins later keeps
            // whatever volume it already had rather than inheriting a
            // mute somebody sent an hour ago.
            guard let req = try? decoder.decode(TransportRequest.self, from: body) else {
                return Self.badRequest()
            }
            if let rejection = await ownerGate(req.token) { return rejection }
            pushTransportSSE(muted: req.muted, volume: req.volume)
            return (200, Data("{\"status\":\"ok\"}".utf8))
        case "/unlike":
            // Un-♥ — a mis-tap shouldn't be forever: clears the signal and
            // removes the file the ♥ copied (never a library original).
            guard let req = try? decoder.decode(LikeRequest.self, from: body),
                  let stationID = UUID(uuidString: req.station) else {
                return Self.badRequest()
            }
            return await performUnlikeAsync(stationID: stationID, token: req.token)
        case "/stations/list":
            // The owner's full catalogue, idle stations included. Token
            // is the whole body — same envelope as /auth.
            return await performStationsListAsync(
                token: (try? decoder.decode(AuthRequest.self, from: body))?.token
            )
        case "/stations/create":
            guard let req = try? decoder.decode(StationCreateRequest.self, from: body) else {
                return Self.badRequest()
            }
            return await performStationCreateAsync(req)
        case "/stations/update":
            guard let req = try? decoder.decode(StationUpdateRequest.self, from: body) else {
                return Self.badRequest()
            }
            return await performStationUpdateAsync(req)
        case "/stations/delete":
            guard let req = try? decoder.decode(StationActionRequest.self, from: body) else {
                return Self.badRequest()
            }
            return await performStationDeleteAsync(req)
        case "/stations/start":
            guard let req = try? decoder.decode(StationActionRequest.self, from: body) else {
                return Self.badRequest()
            }
            return await performStationStartAsync(req)
        case "/stations/stop":
            guard let req = try? decoder.decode(StationActionRequest.self, from: body) else {
                return Self.badRequest()
            }
            return await performStationStopAsync(req)
        case "/stations/autostart":
            guard let req = try? decoder.decode(StationAutoStartRequest.self, from: body) else {
                return Self.badRequest()
            }
            return await performStationAutoStartAsync(req)
        case "/policy/get":
            // The two listener dials plus the read-only mix-set
            // threshold. Token is the whole body, /auth-style.
            return await performPolicyGetAsync(
                token: (try? decoder.decode(AuthRequest.self, from: body))?.token
            )
        case "/policy/set":
            // Sparse overlay; the hand-written decode is what keeps
            // "key absent" distinct from "explicit null" — see
            // ``PolicySetRequest``.
            guard let req = try? decoder.decode(PolicySetRequest.self, from: body) else {
                return Self.badRequest()
            }
            return await performPolicySetAsync(req)
        case "/taste":
            // What the pipeline believes about the owner's taste —
            // library scores + per-station signals, idle stations too.
            return await performTasteAsync(
                token: (try? decoder.decode(AuthRequest.self, from: body))?.token
            )
        case "/exclusions":
            // The mix-set filter's audit trail, shadow rows included.
            guard let req = try? decoder.decode(ExclusionsRequest.self, from: body) else {
                return Self.badRequest()
            }
            return await performExclusionsAsync(req)
        default:
            // Unreachable while dispatch is gated on ``jsonPostPaths``,
            // but a path added to the set without a case must land here
            // rather than silently hang the connection.
            return (404, Data("{\"status\":\"error\",\"message\":\"unknown route\"}".utf8))
        }
    }

    // MARK: - Request parsing

    /// Pull the path out of a request-header byte blob. Returns the raw
    /// path (no query string stripping needed — we don't use queries).
    nonisolated static func requestPath(from bytes: Data) -> String? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        let firstLine = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        // Request line shape: `METHOD SP PATH SP VERSION`.
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    /// Pull the request method (GET / POST / OPTIONS / …) out of the
    /// header byte blob. Uppercased to match the HTTP spec.
    nonisolated static func requestMethod(from bytes: Data) -> String? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        let firstLine = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard let first = parts.first else { return nil }
        return String(first).uppercased()
    }

    /// Extract `Content-Length:` value (integer bytes) from a header blob.
    /// Returns nil when the header is missing or unparseable — callers
    /// should treat that as zero-length body.
    nonisolated static func contentLength(from bytes: Data) -> Int? {
        // The buffer may carry coalesced body bytes past the header
        // terminator (see `readUntilHeaderEnd`) — scan headers only, so
        // a body line can't spoof a header.
        let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? bytes.endIndex
        let headerBytes = bytes.subdata(in: bytes.startIndex..<headerEnd)
        guard let text = String(data: headerBytes, encoding: .utf8) else { return nil }
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalised.split(separator: "\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = lower.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    /// Any body bytes that came along in the same segment as the headers.
    /// `readUntilHeaderEnd` returns its full receive buffer, so whatever
    /// sits past the `\r\n\r\n` terminator is the start of the body — this
    /// peels it off so `readBody` only waits for the remainder.
    nonisolated static func bodyBytes(after headerBytes: Data) -> Data {
        guard let range = headerBytes.range(of: Data("\r\n\r\n".utf8)) else {
            return Data()
        }
        return headerBytes.subdata(in: range.upperBound..<headerBytes.endIndex)
    }

    /// Read the remainder of a request body up to `expected` bytes. If
    /// nothing was pre-buffered and nothing else is coming, returns what
    /// we have. Safe against clients that claim a large body and never
    /// send it (bounded by `expected`, with a timeout).
    ///
    /// `timeout` is the wall clock for the whole body. The 3s default
    /// suits the tiny action payloads; JSON routes pass the roomier
    /// ``jsonBodyReadTimeout`` so a config-sized body arriving slowly
    /// over the tunnel isn't silently truncated into a decode failure.
    nonisolated static func readBody(
        connection: NWConnection,
        alreadyRead: Data,
        expected: Int,
        timeout: TimeInterval = 3
    ) async -> Data {
        var acc = alreadyRead
        let deadline = Date().addingTimeInterval(timeout)
        while acc.count < expected, Date() < deadline {
            let needed = expected - acc.count
            // The deadline above only bounds the loop BETWEEN receives —
            // `connection.receive` itself never times out, so a client
            // that promises Content-Length bytes and goes quiet would
            // park this task forever. The watchdog cancels the connection
            // instead, which forces the pending receive to complete.
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // try? swallows the CancellationError a normal receive
                // triggers — re-check so the happy path can't kill a
                // healthy connection.
                if !Task.isCancelled { connection.cancel() }
            }
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: min(needed, 4_096)
                ) { data, _, _, _ in
                    cont.resume(returning: data)
                }
            }
            watchdog.cancel()
            guard let chunk, !chunk.isEmpty else { break }
            acc.append(chunk)
        }
        return acc
    }

    /// Standard CORS headers for cross-origin POSTs from the GitHub-Pages
    /// web player. The broadcaster is internet-exposed via Cloudflare
    /// Tunnel, so browsers fetch `radio.jonasjohansson.se` directly from
    /// `ratbat.jonasjohansson.se` and the preflight is required.
    nonisolated static func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type"
        ]
    }

    /// Parse `/stream/{slug}.aac` → `slug`. Returns nil for any other
    /// shape so callers 404 instead of guessing.
    nonisolated static func extractSlug(from path: String) -> String? {
        let prefix = "/stream/"
        let suffix = ".aac"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        let slug = String(path[start..<end])
        return slug.isEmpty ? nil : slug
    }

    /// Parse `/artwork/{id}.jpg` → `id`. The id is a hex digest produced by
    /// ``TrackFileProbe/artworkID(for:)``, so anything outside `[0-9a-f]` is
    /// not one of ours and gets no answer — the route is a plain in-memory
    /// dictionary lookup and must never be coaxed into looking like a path.
    nonisolated static func extractArtworkID(from path: String) -> String? {
        let prefix = "/artwork/"
        let suffix = ".jpg"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        let id = String(path[start..<end])
        guard !id.isEmpty, id.count <= 64,
              id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return id
    }

    // MARK: - Response builders

    /// 302 for the legacy `/stream.aac` bookmark, pointing at the
    /// slug-specific path.
    ///
    /// The `Location` is deliberately **host-relative**. RFC 7231 §7.1.2
    /// allows a relative reference and every client resolves it against
    /// the URI the request was made to — so a listener on
    /// `https://radio.jonasjohansson.se` is sent to
    /// `https://radio.jonasjohansson.se/stream/<slug>.aac`, and a local
    /// listener on `localhost:18000` stays local.
    ///
    /// This used to emit an absolute `http://localhost:<port>/…`, which
    /// resolved against the *listener's* machine. It tested green and
    /// curled green from the mac-mini — where `localhost` really is the
    /// origin — and was a dead end for every remote listener. Keep it
    /// relative. `/now.json` already reports `streamURL` the same way.
    nonisolated static func redirectResponse(slug: String) -> String {
        let target = "/stream/\(slug).aac"
        return """
        HTTP/1.1 302 Found\r
        Location: \(target)\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
    }

    nonisolated static func notFoundResponse() -> String {
        """
        HTTP/1.1 404 Not Found\r
        Content-Type: text/plain\r
        Content-Length: 9\r
        Connection: close\r
        \r
        Not Found
        """
    }

    /// Build a generic HTTP/1.1 response with arbitrary headers + body.
    /// Forces `Content-Length` and `Connection: close` so callers can't
    /// forget either — both are load-bearing for our "one request per
    /// connection" flow.
    nonisolated static func buildHTTPResponse(
        status: Int,
        headers: [String: String],
        body: Data
    ) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 204: statusText = "No Content"
        case 302: statusText = "Found"
        case 400: statusText = "Bad Request"
        // Every status a route actually emits needs a row here — the gate
        // used to be missing 403 of all things, so the wire literally read
        // `HTTP/1.1 403 Unknown`. Reason phrases follow RFC 9110 naming.
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 409: statusText = "Conflict"
        case 410: statusText = "Gone"
        case 413: statusText = "Content Too Large"
        case 422: statusText = "Unprocessable Content"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        var merged = headers
        merged["Content-Length"] = "\(body.count)"
        merged["Connection"] = "close"
        // Sort for deterministic ordering — tests that grep the response
        // are happier without map-hashing surprises.
        for key in merged.keys.sorted() {
            response += "\(key): \(merged[key] ?? "")\r\n"
        }
        response += "\r\n"
        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    // MARK: - ♥ Save flow

    /// JSON body accepted by `POST /auth` — just the candidate passcode.
    /// Optional so a malformed or empty body decodes to "no token" and
    /// takes the ordinary rejection path instead of a 400.
    struct AuthRequest: Decodable {
        let token: String?
    }

    /// JSON body accepted by `POST /transport` — the remote control.
    /// Both fields optional and independent: sending `muted` alone must
    /// not disturb a volume the other browsers already have.
    struct TransportRequest: Decodable {
        let token: String?
        let muted: Bool?
        let volume: Double?
    }

    /// JSON body accepted by `POST /like`. Kept internal to the broadcaster
    /// since no caller outside this file assembles one manually.
    struct LikeRequest: Decodable {
        let station: String
        /// Owner token — actions are owner-only; without a valid token the
        /// public surface is listen-only. Optional so old clients decode;
        /// they just get 403 now.
        let token: String?
        /// Retro-♥: an `entryID` from the station's `recent` list saves
        /// that just-played track instead of the current one — "the one
        /// that got away, two tracks back". nil = like the current track.
        let entry: String?
    }

    /// JSON body emitted by `POST /like` (and surfaced from
    /// ``likeCurrent(stationID:)``). `path` is populated on success;
    /// `message` on error.
    public struct LikeResponse: Codable, Sendable {
        public let status: String
        public let path: String?
        public let message: String?
    }

    /// Snapshot of the state `performLikeAsync` needs. Pulled on the main
    /// actor in a single hop so the off-main file copy can run with a
    /// Sendable value and no further main-actor dependencies.
    private struct LikeSnapshot: Sendable {
        let historyID: Int64
        let cachedURL: URL
        let artist: String
        let title: String
        let stationName: String
        let musicFolder: URL
    }

    /// Outcome of the main-actor preflight: a ready-to-execute save
    /// snapshot, an affinity-only mark (track already owned — nothing to
    /// copy, but "♥ = more like this" must still reach the taste
    /// profile), or an early-exit HTTP status + JSON payload.
    private enum LikePreflight {
        case ready(LikeSnapshot)
        case affinity(station: UUID, artist: String, title: String, path: String, existingID: Int64?)
        case early(Int, Data)
    }

    /// Rejection payload for guest requests. 403, not 401: there is no
    /// browser-negotiated login to attempt — the public surface is
    /// listen-only by design, and the web player unlocks itself out of
    /// band via `POST /auth`.
    private static func guestRejection() -> (Int, Data) {
        (403, Data("{\"status\":\"error\",\"message\":\"listener mode\"}".utf8))
    }

    /// Owner gate for every action endpoint: `nil` means "this is the
    /// owner, carry on", anything else is the ready-made rejection.
    ///
    /// Consecutive failures buy a growing delay. Two properties matter:
    ///
    /// 1. Only REJECTIONS are delayed, and a success resets the count.
    ///    A stranger hammering the endpoint therefore cannot lock the
    ///    owner out — the right passcode still answers immediately.
    /// 2. The counter is global rather than per-client on purpose. Every
    ///    request reaches us through cloudflared from localhost, so
    ///    per-IP buckets would all be the same bucket; pretending
    ///    otherwise would be accounting theatre.
    ///
    /// This became worth having when the key stopped being a 122-bit UUID
    /// and became a passcode a human can remember and type.
    func ownerGate(_ token: String?) async -> (Int, Data)? {
        guard preferences.isOwner(token: token) else {
            failedOwnerAttempts += 1
            let over = Double(failedOwnerAttempts - ownerFreeAttempts)
            if over > 0 {
                let delay = min(over * ownerThrottleStep, ownerThrottleCeiling)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            return Self.guestRejection()
        }
        failedOwnerAttempts = 0
        return nil
    }

    /// Answer whether a passcode is the owner's, with no side effect.
    ///
    /// Exists so the web player's unlock prompt can say "wrong passcode"
    /// without having to ♥ or skip something to find out. Before this the
    /// only way to test a key was to perform an action, which is a side
    /// effect nobody asked for and which lands in the play history.
    func performAuthAsync(token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }
        return (200, Data("{\"status\":\"ok\"}".utf8))
    }

    /// Main-actor pre-flight: resolve everything the save needs into a
    /// Sendable snapshot, or return an early-exit status + payload.
    #if os(macOS)
    private func likePreflight(stationID: UUID) -> LikePreflight {
        guard let pipeline = pipelines[stationID] else {
            return .early(404, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "no current track"
            )))
        }
        guard let item = currentItemByStation[stationID] else {
            return .early(404, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "no current track"
            )))
        }
        guard !item.isOwned, let historyID = item.historyID else {
            // Already in the library (or never recorded): nothing to
            // acquire — but ♥ still means "more like this". Record it as
            // affinity instead of refusing, so the user's own collection
            // feeds the taste profile. Gated on `isOwned`, not on a
            // missing history row: playlist plays are recorded now too. Artist is the key the profile matches on; without
            // one the signal is meaningless, so that case stays an error.
            guard history != nil else {
                return .early(500, Self.encodeLikeResponse(LikeResponse(
                    status: "error", path: nil, message: "history unavailable"
                )))
            }
            guard let artist = item.artist,
                  !artist.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .early(422, Self.encodeLikeResponse(LikeResponse(
                    status: "error", path: nil, message: "track has no artist metadata"
                )))
            }
            return .affinity(
                station: stationID,
                artist: artist,
                title: item.title ?? "Unknown",
                path: item.url.path,
                existingID: item.historyID
            )
        }
        guard history != nil else {
            return .early(500, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "history unavailable"
            )))
        }
        guard let musicFolder = libraryConfig?.musicFolder else {
            return .early(500, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "music folder not set"
            )))
        }
        return .ready(LikeSnapshot(
            historyID: historyID,
            cachedURL: item.url,
            artist: item.artist ?? "Unknown",
            title: item.title ?? "Unknown",
            stationName: pipeline.stationName,
            musicFolder: musicFolder
        ))
    }

    /// Async save flow used by both the HTTP `/like` handler and the
    /// in-app ♥ button. Resolves state on the main actor, copies off-main,
    /// then updates history and returns the wire-shaped response.
    ///
    /// Steps:
    /// 1. Find the pipeline + current item for `stationID`.
    /// 2. If the item has no `historyID` (playlist tracks — already in
    ///    the user's library), record an affinity-only ♥: a saved-flagged
    ///    history row with no file copy, so owned music feeds the taste
    ///    profile too. Wire status: "noted".
    /// 3. Otherwise: file copy + `history.markSaved` off the main actor.
    ///    Wire status: "saved".
    func performLikeAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }
        let snapshot: LikeSnapshot
        switch likePreflight(stationID: stationID) {
        case .early(let status, let data):
            return (status, data)
        case .affinity(let station, let artist, let title, let path, let existingID):
            // Owned track — no copy, just the taste signal. A saved-
            // flagged history row is exactly what `savedEntries(forStation:)`
            // feeds into the graduated ♥-affinity, so this rides the same
            // rails as a real save. Repeat ♥s of the same track on later
            // plays insert repeat rows deliberately: "I still like this"
            // is a stronger signal, and the affinity curve saturates.
            guard let history else {
                return (500, Self.encodeLikeResponse(LikeResponse(
                    status: "error", path: nil, message: "history unavailable"
                )))
            }
            do {
                // The play may already have a row (playlist plays are
                // recorded); flag that one rather than inserting a twin.
                let id: Int64
                if let existingID {
                    id = existingID
                } else {
                    id = try await history.record(
                        station: station,
                        artist: artist,
                        title: title,
                        cachedPath: path
                    )
                }
                try await history.markSaved(id: id, cachedPath: path)
                logger.info("♥ noted (owned): \(artist, privacy: .public) — \(title, privacy: .public)")
                return (200, Self.encodeLikeResponse(LikeResponse(
                    status: "noted", path: path, message: nil
                )))
            } catch {
                logger.error("♥ affinity mark failed: \(String(describing: error), privacy: .public)")
                return (500, Self.encodeLikeResponse(LikeResponse(
                    status: "error", path: nil, message: "could not record"
                )))
            }
        case .ready(let ok):
            snapshot = ok
        }
        // history must be non-nil here (preflight would have returned).
        guard let history else {
            return (500, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "history unavailable"
            )))
        }

        do {
            let destinationPath = try await Task.detached(priority: .userInitiated) {
                try Self.saveCached(
                    cachedURL: snapshot.cachedURL,
                    artist: snapshot.artist,
                    title: snapshot.title,
                    stationName: snapshot.stationName,
                    musicFolder: snapshot.musicFolder
                )
            }.value
            try await history.markSaved(id: snapshot.historyID, cachedPath: destinationPath)
            logger.info("♥ saved \(snapshot.artist, privacy: .public) — \(snapshot.title, privacy: .public) to \(destinationPath, privacy: .public)")
            return (200, Self.encodeLikeResponse(LikeResponse(
                status: "saved", path: destinationPath, message: nil
            )))
        } catch {
            logger.error("♥ save failed: \(String(describing: error), privacy: .public)")
            return (500, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: String(describing: error)
            )))
        }
    }

    /// Async bridge for the HTTP `POST /skip` handler. Validates there's a
    /// skippable track, then reuses ``skipCurrent(stationID:)`` (mark
    /// skipped + nudge the encode loop) and returns a wire-shaped JSON
    /// status. 404 when nothing's skippable (no pipeline / no current item /
    /// playlist track with no historyID), 200 on success — mirroring the
    /// shape `/like` returns.
    func performSkipAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }
        guard pipelines[stationID] != nil,
              let item = currentItemByStation[stationID],
              item.historyID != nil else {
            return (404, Data("{\"status\":\"error\",\"message\":\"no current track\"}".utf8))
        }
        await skipCurrent(stationID: stationID)
        return (200, Data("{\"status\":\"skipped\"}".utf8))
    }

    /// Async bridge for `POST /next` — advance without judging. Unlike
    /// `performSkipAsync` there's no `historyID` requirement: "not right
    /// now" applies to playlist-backed stations too (their tracks carry
    /// no history row, which is exactly why 👎 refuses them — a neutral
    /// advance records nothing, so it has nothing to refuse).
    func performNextAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }
        guard pipelines[stationID] != nil,
              currentItemByStation[stationID] != nil else {
            return (404, Data("{\"status\":\"error\",\"message\":\"no current track\"}".utf8))
        }
        nextTrack(stationID: stationID)
        return (200, Data("{\"status\":\"next\"}".utf8))
    }

    /// Advance to the next track with no taste signal recorded — the
    /// listener-neutral counterpart of ``skipCurrent(stationID:)``. Same
    /// encode-loop nudge, none of the history/blacklist side effects.
    public func nextTrack(stationID: Station.ID) {
        guard pipelines[stationID] != nil,
              currentItemByStation[stationID] != nil else { return }
        pipelines[stationID]?.skipRequested = true
        logger.info("⏭ next requested for \(stationID.uuidString.prefix(8), privacy: .public)")
    }

    /// Retro-♥ — save a track from the recent ring instead of the current
    /// one. Owned tracks (no historyID) get the affinity treatment; cached
    /// tracks get the normal copy, unless the transient cache's LRU cap
    /// already evicted the file — then 410, honestly gone.
    func performRetroLikeAsync(stationID: UUID, entryID: String, token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }
        guard let uuid = UUID(uuidString: entryID),
              let rec = (recentByStation[stationID] ?? []).first(where: { $0.entryID == uuid }) else {
            return (404, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "not in recent history"
            )))
        }
        guard let history else {
            return (500, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "history unavailable"
            )))
        }
        let item = rec.item

        // Owned/playlist track — record affinity, nothing to copy.
        guard !item.isOwned, let historyID = item.historyID else {
            guard let artist = item.artist,
                  !artist.trimmingCharacters(in: .whitespaces).isEmpty else {
                return (422, Self.encodeLikeResponse(LikeResponse(
                    status: "error", path: nil, message: "track has no artist metadata"
                )))
            }
            do {
                let id = try await history.record(
                    station: stationID,
                    artist: artist,
                    title: item.title ?? "Unknown",
                    cachedPath: item.url.path
                )
                try await history.markSaved(id: id, cachedPath: item.url.path)
                return (200, Self.encodeLikeResponse(LikeResponse(
                    status: "noted", path: item.url.path, message: nil
                )))
            } catch {
                return (500, Self.encodeLikeResponse(LikeResponse(
                    status: "error", path: nil, message: "could not record"
                )))
            }
        }

        // Generative track — the cached file may have been LRU-evicted
        // since it played.
        guard let musicFolder = libraryConfig?.musicFolder else {
            return (500, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "music folder not set"
            )))
        }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            return (410, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "no longer cached"
            )))
        }
        let stationName = pipelines[stationID]?.stationName ?? "Radio"
        let cachedURL = item.url
        let artist = item.artist ?? "Unknown"
        let title = item.title ?? "Unknown"
        do {
            let destinationPath = try await Task.detached(priority: .userInitiated) {
                try Self.saveCached(
                    cachedURL: cachedURL,
                    artist: artist,
                    title: title,
                    stationName: stationName,
                    musicFolder: musicFolder
                )
            }.value
            try await history.markSaved(id: historyID, cachedPath: destinationPath)
            logger.info("♥ retro-saved \(artist, privacy: .public) — \(title, privacy: .public)")
            return (200, Self.encodeLikeResponse(LikeResponse(
                status: "saved", path: destinationPath, message: nil
            )))
        } catch {
            return (500, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "save failed"
            )))
        }
    }

    /// Boost the current track — "more of this". Stamps `boosted_at` on
    /// its history row (creating one for owned tracks, same as affinity-♥),
    /// which puts the artist at the front of the next similar-artist
    /// expansion via ``HistoryStore/topAffinityArtists`` and feeds the
    /// scoring term weighted above ♥-saves. The refill no longer waits
    /// for the pool to drain: the boosted artist becomes a seed override
    /// and a debounced refill is scheduled
    /// (``noteBoostSteering(stationID:artist:)``), with rapid boosts
    /// folding into one refill. The track on air always finishes —
    /// steering moves the pool, never the needle.
    func performBoostAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }
        guard pipelines[stationID] != nil,
              let item = currentItemByStation[stationID] else {
            return (404, Data("{\"status\":\"error\",\"message\":\"no current track\"}".utf8))
        }
        guard let history else {
            return (500, Data("{\"status\":\"error\",\"message\":\"history unavailable\"}".utf8))
        }
        do {
            if let historyID = item.historyID {
                try await history.markBoosted(id: historyID)
            } else {
                guard let artist = item.artist,
                      !artist.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return (422, Data("{\"status\":\"error\",\"message\":\"track has no artist metadata\"}".utf8))
                }
                let id = try await history.record(
                    station: stationID,
                    artist: artist,
                    title: item.title ?? "Unknown",
                    cachedPath: item.url.path
                )
                try await history.markBoosted(id: id)
            }
            // Only after the signal is durably recorded: a steering nudge
            // for a boost that failed to write would promise a change the
            // profile never heard about.
            noteBoostSteering(stationID: stationID, artist: item.artist)
            logger.info("boost: \(item.artist ?? "?", privacy: .public) — \(item.title ?? "?", privacy: .public)")
            return (200, Data("{\"status\":\"boosted\"}".utf8))
        } catch {
            return (500, Data("{\"status\":\"error\",\"message\":\"could not record\"}".utf8))
        }
    }

    /// Un-♥ the current track. Finds the save row (by id for generative
    /// tracks, by newest station+artist+title match for owned ones, whose
    /// items don't carry a row id) and undoes what ♥ did:
    /// - generative save → clear the flag, delete the COPIED file
    /// - owned/affinity ♥ → delete the row (it exists only as the signal)
    ///
    /// File deletion is allowed ONLY for paths inside the music folder
    /// whose parent is a dated radio-save folder (`YYMMDD …`) — a library
    /// original can never match, so un-♥ can never delete your own record.
    func performUnlikeAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }
        guard pipelines[stationID] != nil,
              let item = currentItemByStation[stationID] else {
            return (404, Data("{\"status\":\"error\",\"message\":\"no current track\"}".utf8))
        }
        guard let history else {
            return (500, Data("{\"status\":\"error\",\"message\":\"history unavailable\"}".utf8))
        }
        do {
            let row: HistoryStore.Entry?
            if let historyID = item.historyID {
                row = try await history.entry(id: historyID)
            } else if let artist = item.artist, let title = item.title {
                row = try await history.newestSavedEntry(
                    station: stationID, artist: artist, title: title
                )
            } else {
                row = nil
            }
            guard let row, row.saved else {
                return (404, Data("{\"status\":\"error\",\"message\":\"not liked\"}".utf8))
            }

            var deletedFile = false
            if let cachedPath = row.cachedPath,
               let musicFolder = libraryConfig?.musicFolder {
                let url = URL(fileURLWithPath: cachedPath)
                let parent = url.deletingLastPathComponent().lastPathComponent
                let inLibrary = url.path.hasPrefix(musicFolder.path)
                let isDatedRadioFolder = parent.count > 6
                    && parent.prefix(6).allSatisfy(\.isNumber)
                    && parent[parent.index(parent.startIndex, offsetBy: 6)] == " "
                if inLibrary && isDatedRadioFolder {
                    try? FileManager.default.removeItem(at: url)
                    deletedFile = true
                }
            }

            // Always clear the flag, never drop the row. Since the
            // history slice every ♥ attaches to a real play record, so
            // deleting it would erase the fact the track was ever
            // heard — undoing a save must not rewrite history.
            try await history.unmarkSaved(id: row.id)
            logger.info("un-♥: \(row.artist, privacy: .public) — \(row.title, privacy: .public) (file deleted: \(deletedFile))")
            return (200, Data("{\"status\":\"unliked\"}".utf8))
        } catch {
            return (500, Data("{\"status\":\"error\",\"message\":\"could not undo\"}".utf8))
        }
    }

    /// Public in-app entry point for the Mac UI's ♥ button. Thin async
    /// wrapper over ``performLikeAsync(stationID:token:)`` that hands back
    /// the decoded response so callers can render state directly. The Mac
    /// UI is the owner by definition, so it self-authorizes.
    @discardableResult
    public func likeCurrent(stationID: Station.ID) async -> LikeResponse {
        let (_, data) = await performLikeAsync(stationID: stationID, token: preferences.ownerToken)
        if let decoded = try? JSONDecoder().decode(LikeResponse.self, from: data) {
            return decoded
        }
        return LikeResponse(status: "error", path: nil, message: "decode failed")
    }

    /// Copy the cached file into `~/<musicFolder>/<YYMMDD> <station>/<artist> — <title>.m4a`.
    /// Idempotent: if the destination already exists we return its path
    /// rather than throwing — double-click ♥ means "yes, still saved",
    /// not "error".
    ///
    /// The folder name carries today's date + the station so each day of
    /// broadcasting builds a dated mix-tape folder. A save today lands
    /// in `260418 90s Techno/`, tomorrow's in `260419 90s Techno/` — if
    /// the station plays overnight the folder rolls naturally at
    /// midnight (the formatter resolves `Date()` at save time, not
    /// broadcast-start time).
    nonisolated private static func saveCached(
        cachedURL: URL,
        artist: String,
        title: String,
        stationName: String,
        musicFolder: URL
    ) throws -> String {
        let stamp = yymmddFormatter.string(from: Date())
        let folder = musicFolder.appendingPathComponent(
            "\(stamp) \(sanitize(stationName))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let filename = "\(sanitize(artist)) — \(sanitize(title)).m4a"
        let destination = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination.path
        }
        try FileManager.default.copyItem(at: cachedURL, to: destination)
        return destination.path
    }

    /// Date formatter for the save-folder prefix. Short-form (YYMMDD),
    /// POSIX locale + UTC so the stamp lines up across time-zone changes
    /// instead of shifting when the user flies somewhere new.
    nonisolated private static let yymmddFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd"
        return f
    }()

    /// Replace characters that trip macOS or URL handling (slashes,
    /// control chars, `:` which confuses classic Finder, Windows-reserved
    /// glyphs) with underscores. We keep em-dashes and Unicode letters
    /// so "Björk" / "Rödhåret" survive intact.
    nonisolated private static func sanitize(_ s: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:*?\"<>|\\\n\r\t")
        let replaced = s.unicodeScalars.map { scalar -> String in
            if forbidden.contains(scalar) { return "_" }
            return String(scalar)
        }.joined()
        let trimmed = replaced.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "_" : trimmed
    }

    /// Serialise a LikeResponse to JSON for the wire. Used by both the
    /// HTTP handler and the in-app UI path, so shape is consistent.
    nonisolated private static func encodeLikeResponse(_ response: LikeResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(response)) ?? Data("{\"status\":\"error\"}".utf8)
    }
    #else
    /// iOS stub — broadcaster isn't wired for NTS / library on iOS, so a
    /// like always reports "unavailable". Kept so cross-platform code
    /// compiles without `#if` at every call site.
    func performLikeAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        let payload = Data("{\"message\":\"unavailable\",\"path\":null,\"status\":\"error\"}".utf8)
        return (500, payload)
    }

    /// iOS stub — skip needs the macOS encode pipeline, so report
    /// unavailable. Kept so cross-platform call sites compile without `#if`.
    func performSkipAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        (500, Data("{\"status\":\"error\",\"message\":\"unavailable\"}".utf8))
    }

    /// iOS stub — same rationale as ``performSkipAsync(stationID:)``.
    func performNextAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        (500, Data("{\"status\":\"error\",\"message\":\"unavailable\"}".utf8))
    }

    /// iOS stub — same rationale as the other action stubs.
    func performRetroLikeAsync(stationID: UUID, entryID: String, token: String?) async -> (Int, Data) {
        (500, Data("{\"status\":\"error\",\"message\":\"unavailable\"}".utf8))
    }

    /// iOS stub — same rationale as the other action stubs.
    func performBoostAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        (500, Data("{\"status\":\"error\",\"message\":\"unavailable\"}".utf8))
    }

    /// iOS stub — same rationale as the other action stubs.
    func performUnlikeAsync(stationID: UUID, token: String?) async -> (Int, Data) {
        (500, Data("{\"status\":\"error\",\"message\":\"unavailable\"}".utf8))
    }

    @discardableResult
    public func likeCurrent(stationID: Station.ID) async -> LikeResponse {
        LikeResponse(status: "error", path: nil, message: "unavailable")
    }
    #endif

    // MARK: - Status payload

    /// Snapshot the current broadcast state as JSON. Only broadcasting
    /// stations are included — the broadcaster doesn't know about the
    /// user's wider library, and that's deliberate (no library leakage
    /// over the public endpoint).
    /// JSON for `/history?limit=&offset=`. Reads the store (not the
    /// in-memory ring), so it survives restarts. Station names are
    /// resolved from live pipelines where possible; historical rows from
    /// stations that aren't currently broadcasting just carry their id.
    func buildHistoryPayload(path: String) async -> Data {
        /// `stationID` is the row's real key — the stable UUID history has
        /// always stored. `station` is a display name resolved against the
        /// current catalogue, so a rename shows up immediately and an idle
        /// station is still named. It is `null`, never `""`, when the
        /// station has been deleted: the row keeps its id and stays
        /// attributable, we just can't say what it used to be called.
        struct HistoryEntry: Encodable {
            let id: Int64
            let artist: String
            let title: String
            let playedAt: Double
            let stationID: String
            let station: String?
            let saved: Bool
            let youtubeURL: String?
            let sourceURL: String?

            enum CodingKeys: String, CodingKey {
                case id, artist, title, playedAt, stationID, station
                case saved, youtubeURL, sourceURL
            }

            /// Hand-written so a nil `station` encodes as an explicit JSON
            /// null rather than a missing key — a client should be able to
            /// tell "unnamed" from "field not in this build".
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(artist, forKey: .artist)
                try c.encode(title, forKey: .title)
                try c.encode(playedAt, forKey: .playedAt)
                try c.encode(stationID, forKey: .stationID)
                try c.encode(station, forKey: .station)
                try c.encode(saved, forKey: .saved)
                // Explicit nulls, like every other field here. These two
                // were the last `encodeIfPresent` on the wire, so a
                // Bandcamp row (no YouTube match) and a Last.fm row (no
                // source page) each came back missing a different key —
                // the same shape complaint /now.json was fixed for.
                try c.encode(youtubeURL, forKey: .youtubeURL)
                try c.encode(sourceURL, forKey: .sourceURL)
            }
        }
        struct HistoryResponse: Encodable {
            let entries: [HistoryEntry]
        }

        // Tiny query parse — the router keeps the query string on `path`.
        var limit = 50
        var offset = 0
        if let q = path.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, let value = Int(kv[1]) else { continue }
                if kv[0] == "limit" { limit = min(max(value, 1), 200) }
                if kv[0] == "offset" { offset = max(value, 0) }
            }
        }

        #if os(macOS)
        guard let history,
              let rows = try? await history.recentEntries(limit: limit, offset: offset) else {
            return Data("{\"entries\":[]}".utf8)
        }
        let entries = rows.map { row in
            HistoryEntry(
                id: row.id,
                artist: row.artist,
                title: row.title,
                playedAt: row.playedAt.timeIntervalSince1970,
                stationID: row.stationID.uuidString,
                // The catalogue, not the live pipelines: an idle station is
                // still a station the user has, and a renamed one answers
                // to its new name from the moment it is renamed.
                station: stationNames[row.stationID],
                saved: row.saved,
                // Same filter `/now.json` applies: the direct-URL resolver
                // path stores a SYNTHETIC `"<extractor>:<id>"` in the
                // youtube_id column, and pasting that into a watch?v=
                // template yields a link that 404s. `/history` was still
                // minting them after /now.json stopped — verifying the
                // deploy from outside is what caught the gap.
                youtubeURL: TrackSourceItem.youtubeWatchURL(for: row.youtubeID),
                sourceURL: row.sourceShowURL?.absoluteString
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(HistoryResponse(entries: entries)))
            ?? Data("{\"entries\":[]}".utf8)
        #else
        return Data("{\"entries\":[]}".utf8)
        #endif
    }

    // MARK: - Health payload

    /// What this build's HTTP surface can do, for web capability gating.
    /// The anchor the web client reads instead of 404-probing each route.
    /// Append-only: a control appears on the web iff its capability is
    /// listed, so entries are added as features land (`stations` will
    /// join with the CRUD routes) and never renamed.
    nonisolated static let healthCapabilities = [
        "health", "stations", "vocab", "policy", "taste", "exclusions",
        "trackinfo", "transport"
    ]
    /// Window over which `/health` judges each station's liveness.
    /// Ten minutes ≈ a handful of heartbeats: long enough that one
    /// missed beat doesn't flap the answer, short enough to notice an
    /// outage while it still matters.
    nonisolated static let healthLivenessWindow: TimeInterval = 10 * 60
    /// Window over which `/health` looks for the most recent off-air gap
    /// — "did the radio go dark in the last day, and when".
    nonisolated static let healthGapWindow: TimeInterval = 24 * 60 * 60

    #if os(macOS)
    /// Wire spelling of ``HistoryStore/Liveness`` — the case names,
    /// pinned here so a Swift-side rename can't silently change the API.
    nonisolated static func livenessLabel(_ liveness: HistoryStore.Liveness) -> String {
        switch liveness {
        case .onAirAndPlaying: return "onAirAndPlaying"
        case .onAirButQuiet: return "onAirButQuiet"
        case .offAir: return "offAir"
        }
    }
    #endif

    /// JSON for `GET /health` — the deploy-verification surface. Reads
    /// the heartbeat table so "off air" and "on air but quiet" can be
    /// told apart after the fact, which no status line can do.
    ///
    /// Always a 200: "degraded" (no history store) is a payload fact,
    /// not a transport failure, so an outside probe can tell
    /// "broadcaster up but storeless" from "socket dead".
    func buildHealthPayload() async -> Data {
        /// Same wire-shape rules as /now.json: every key always present,
        /// explicit nulls, sorted keys.
        struct HealthGap: Encodable {
            let start: Double
            let end: Double
        }
        struct HealthStation: Encodable {
            let id: String
            let name: String?
            let slug: String?
            let broadcasting: Bool
            let liveness: String
            let lastGap: HealthGap?

            enum CodingKeys: String, CodingKey {
                case id, name, slug, broadcasting, liveness, lastGap
            }

            /// Hand-written so a nil name/slug (a deleted station whose
            /// heartbeats outlive its catalogue entry) and a gap-free day
            /// encode as explicit JSON nulls rather than missing keys.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(slug, forKey: .slug)
                try c.encode(broadcasting, forKey: .broadcasting)
                try c.encode(liveness, forKey: .liveness)
                try c.encode(lastGap, forKey: .lastGap)
            }
        }
        struct HealthResponse: Encodable {
            let status: String
            let version: String
            let capabilities: [String]
            let uptimeSeconds: Double
            let broadcastingCount: Int
            let stations: [HealthStation]
        }

        // Bundle.main is the app in production and the xctest runner
        // under test; "dev" is the honest fallback for a bare binary.
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        func payload(status: String, stations: [HealthStation]) -> Data {
            let response = HealthResponse(
                status: status,
                version: version,
                capabilities: Self.healthCapabilities,
                uptimeSeconds: Date().timeIntervalSince(startedAt),
                broadcastingCount: broadcasting.count,
                stations: stations
            )
            return (try? encoder.encode(response)) ?? Data("{\"status\":\"error\"}".utf8)
        }

        #if os(macOS)
        guard let history else { return payload(status: "degraded", stations: []) }

        let now = Date()
        let livenessFrom = now.addingTimeInterval(-Self.healthLivenessWindow)
        let gapFrom = now.addingTimeInterval(-Self.healthGapWindow)

        // Currently broadcasting ∪ heartbeated inside the gap window.
        // Anything in either set was public on /now.json while it was
        // live — no new leak — and idle-forever stations never appear.
        var ids = broadcasting
        if let beating = try? await history.stationsWithHeartbeats(from: gapFrom, to: now) {
            ids.formUnion(beating)
        }

        var stations: [HealthStation] = []
        for id in ids {
            let liveness = (try? await history.liveness(
                station: id, from: livenessFrom, to: now
            )) ?? .offAir
            // One most-recent gap, not the whole day's list — the client
            // renders a single "went dark 03:12–04:40" line.
            let gaps = (try? await history.offAirGaps(
                station: id, from: gapFrom, to: now,
                expectedInterval: Self.heartbeatInterval
            )) ?? []
            stations.append(HealthStation(
                id: id.uuidString,
                name: pipelines[id]?.station.name ?? stationNames[id],
                slug: pipelines[id]?.station.slug ?? stationSlugs[id],
                broadcasting: broadcasting.contains(id),
                liveness: Self.livenessLabel(liveness),
                lastGap: gaps.last.map {
                    HealthGap(
                        start: $0.start.timeIntervalSince1970,
                        end: $0.end.timeIntervalSince1970
                    )
                }
            ))
        }
        // Stable ordering by name so UI doesn't jitter between polls,
        // same as /now.json; id breaks ties and orders the nameless.
        stations.sort { ($0.name ?? "", $0.id) < ($1.name ?? "", $1.id) }
        return payload(status: "ok", stations: stations)
        #else
        return payload(status: "degraded", stations: [])
        #endif
    }

    /// One track, however it reached us.
    ///
    /// Every field is emitted on every track object — current, recent, or
    /// next — with `null` where the origin genuinely has nothing to say. The
    /// previous shape omitted keys per source, so a client could not tell
    /// "Bandcamp has no album for this single" from "the library path never
    /// plumbed album through". `origin` names the source so a null is
    /// attributable; see ``TrackSourceItem`` for the per-origin table.
    ///
    /// `nil` optionals must still encode as JSON `null`, so every field is
    /// written explicitly rather than through the synthesised encoder,
    /// which skips nils.
    struct NowTrack: Encodable {
        let title: String
        let artist: String
        let album: String?
        let durationSeconds: Double?
        let artworkURL: String?
        let sourceURL: String?
        let youtubeURL: String?
        let origin: String
        /// How far into this track the broadcast is, in seconds. Non-null
        /// only for a station's CURRENT track — a track in the recent ring
        /// is over and one in `nextTrack` has not begun, and publishing a
        /// number for either would invite a client to render a clock for
        /// something that is not playing.
        let elapsedSeconds: Double?

        init(_ item: TrackSourceItem, startedAt: Date? = nil) {
            self.title = item.title ?? ""
            self.artist = item.artist ?? ""
            self.album = item.album
            self.durationSeconds = item.duration
            self.artworkURL = item.artworkURL
            self.sourceURL = item.sourceURL
            self.youtubeURL = item.youtubeURL
            self.origin = item.origin.rawValue
            // Elapsed rather than a start timestamp: a client's clock can
            // be minutes off a server's, and a delta measured at the
            // moment of the response needs neither side to agree on what
            // time it is. Clamped to the track's own length so a station
            // parked at a boundary cannot report a track more than
            // finished.
            if let startedAt {
                let raw = Date().timeIntervalSince(startedAt)
                self.elapsedSeconds = max(0, item.duration.map { min(raw, $0) } ?? raw)
            } else {
                self.elapsedSeconds = nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case title, artist, album, durationSeconds, artworkURL
            case sourceURL, youtubeURL, origin, elapsedSeconds
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encode(artist, forKey: .artist)
            // `encode` (not `encodeIfPresent`) so nil becomes an explicit
            // JSON null instead of a missing key.
            try c.encode(album, forKey: .album)
            try c.encode(durationSeconds, forKey: .durationSeconds)
            try c.encode(artworkURL, forKey: .artworkURL)
            try c.encode(sourceURL, forKey: .sourceURL)
            try c.encode(youtubeURL, forKey: .youtubeURL)
            try c.encode(origin, forKey: .origin)
            try c.encode(elapsedSeconds, forKey: .elapsedSeconds)
        }
    }

    /// A recent play: a track object plus its own identity, so the web
    /// player can retro-♥ "the one two tracks back".
    struct RecentPayload: Encodable {
        let track: NowTrack
        let entryID: String
        let playedAt: Double

        enum CodingKeys: String, CodingKey { case entryID, playedAt }

        func encode(to encoder: Encoder) throws {
            try track.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(entryID, forKey: .entryID)
            try c.encode(playedAt, forKey: .playedAt)
        }
    }

    private func buildNowPayload() -> Data {
        /// Same rule as ``NowTrack``, one level up: every key is always
        /// present, null where there is nothing. The synthesised encoder
        /// dropped `currentTrack` / `nextTrack` when nil, so a station with
        /// nothing prefetched had a different key set from its neighbour in
        /// the same payload — which is the exact complaint the track shape
        /// was fixed for.
        struct NowStation: Encodable {
            let id: String
            let name: String
            let slug: String
            let broadcasting: Bool
            let streamURL: String?
            let listeners: Int
            let currentTrack: NowTrack?
            let recent: [RecentPayload]
            let nextTrack: NowTrack?

            enum CodingKeys: String, CodingKey {
                case id, name, slug, broadcasting, streamURL
                case listeners, currentTrack, recent, nextTrack
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(slug, forKey: .slug)
                try c.encode(broadcasting, forKey: .broadcasting)
                try c.encode(streamURL, forKey: .streamURL)
                try c.encode(listeners, forKey: .listeners)
                try c.encode(currentTrack, forKey: .currentTrack)
                try c.encode(recent, forKey: .recent)
                try c.encode(nextTrack, forKey: .nextTrack)
            }
        }
        struct NowResponse: Encodable {
            let stations: [NowStation]
            /// How far ahead of the listener the encoder deliberately runs.
            /// The client needs it to answer "is the track I am announcing
            /// the one in your ears yet?" — see ``broadcastLeadSeconds``.
            let leadSeconds: Double
        }

        // Stable ordering by station name so UI doesn't jitter between
        // polls. Dictionary iteration isn't deterministic in Swift.
        let ordered = pipelines.values.sorted { $0.station.name < $1.station.name }
        let stations: [NowStation] = ordered.map { pipeline in
            let stationID = pipeline.station.id
            return NowStation(
                id: stationID.uuidString,
                name: pipeline.station.name,
                slug: pipeline.station.slug,
                broadcasting: true,
                streamURL: "/stream/\(pipeline.station.slug).aac",
                listeners: listenerCount[stationID] ?? 0,
                currentTrack: currentItemByStation[stationID].map {
                    NowTrack($0, startedAt: currentItemStartedAt[stationID])
                },
                recent: (recentByStation[stationID] ?? []).map {
                    RecentPayload(
                        track: NowTrack($0.item),
                        entryID: $0.entryID.uuidString,
                        playedAt: $0.playedAt.timeIntervalSince1970
                    )
                },
                nextTrack: upcomingByStation[stationID].map { NowTrack($0) }
            )
        }

        let response = NowResponse(
            stations: stations,
            leadSeconds: Self.broadcastLeadSeconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(response))
            ?? Data("{\"leadSeconds\":\(Self.broadcastLeadSeconds),\"stations\":[]}".utf8)
    }

    // MARK: - Client serving (detached)

    /// Reads were already done in `routeIncoming`; this writes the 200
    /// header and pumps the pipeline's ring buffer to the client. ICY
    /// metadata (if requested) is injected every 16384 bytes using the
    /// station's current track.
    /// How long a listener waits on a cold start before we admit the
    /// station isn't ready. Long enough to cover a slow first resolve,
    /// short enough that a player's own timeout doesn't beat us to it.
    nonisolated static let coldStartTimeout: TimeInterval = 12

    /// Poll for the ring's first byte. Returns false on timeout.
    nonisolated private static func awaitFirstAudio(
        buffer: AACRingBuffer,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if buffer.hasProducedAudio() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return buffer.hasProducedAudio()
    }

    /// 503 for a station that is registered but has produced no audio yet.
    /// `Retry-After` tells a well-behaved player to come back rather than
    /// treat the station as permanently broken.
    nonisolated static func serviceUnavailableResponse() -> String {
        let body = "not ready"
        return """
        HTTP/1.1 503 Service Unavailable\r
        Content-Type: text/plain\r
        Content-Length: \(body.utf8.count)\r
        Retry-After: 5\r
        Connection: close\r
        \r
        \(body)
        """
    }

    nonisolated private static func serveClient(
        connection: NWConnection,
        buffer: AACRingBuffer,
        stationID: Station.ID,
        stationName: String,
        wantsMetadata: Bool,
        ownerRef: @escaping @Sendable () -> RadioBroadcaster?
    ) async {
        // Don't promise a stream we can't yet fill.
        //
        // The pipeline is registered — and so serves 200 + ICY headers,
        // and reports broadcasting:true — before the first track has
        // resolved. A new listener's cursor starts at the live edge of an
        // empty ring, so the player got a valid-looking `200 audio/aac`
        // and then silence for however long the resolve took (~18s for a
        // Bandcamp first track via yt-dlp). Most players give up, and the
        // window is indistinguishable from a genuinely broken station to
        // any check that only reads the status line.
        //
        // Wait, bounded, for the first byte. If it never comes, say so
        // honestly with a retryable 503 instead of a 200 that lies.
        if !buffer.hasProducedAudio() {
            let ready = await awaitFirstAudio(
                buffer: buffer,
                timeout: coldStartTimeout
            )
            if !ready {
                _ = await send(
                    data: Data(serviceUnavailableResponse().utf8),
                    on: connection
                )
                return
            }
        }

        let responseHeader = buildResponseHeader(
            wantsMetadata: wantsMetadata,
            stationName: stationName
        )
        let sent = await send(data: Data(responseHeader.utf8), on: connection)
        guard sent else { return }

        var cursor = buffer.readCursor()
        var bytesSinceMetaBlock = 0
        // Track-change detection: the underlying source may not have a UUID
        // (NTS items don't carry a stable library ID), so key on the URL
        // which is always present and unique per resolved file.
        var lastAnnouncedURL: URL?

        while !Task.isCancelled {
            let chunk = await buffer.read(from: &cursor)
            if chunk.isEmpty {
                if Task.isCancelled { return }
                continue
            }

            if !wantsMetadata {
                // Fast path for dumb clients: pure AAC, no framing.
                let ok = await send(data: chunk, on: connection)
                if !ok { return }
                continue
            }

            // ICY path: split the chunk on the 16384-byte boundary and
            // inject metadata blocks between audio slices. The counter
            // tracks AUDIO bytes only — the metadata itself must NOT
            // shift the next boundary.
            var remaining = chunk
            while !remaining.isEmpty {
                let room = ICYMetadata.blockInterval - bytesSinceMetaBlock
                if remaining.count < room {
                    let ok = await send(data: remaining, on: connection)
                    if !ok { return }
                    bytesSinceMetaBlock += remaining.count
                    remaining = Data()
                } else {
                    let fill = remaining.prefix(room)
                    if !fill.isEmpty {
                        let ok = await send(data: Data(fill), on: connection)
                        if !ok { return }
                    }
                    remaining = remaining.dropFirst(room)

                    let item = await MainActor.run {
                        ownerRef()?.snapshotCurrentItem(stationID: stationID)
                    }
                    let trackChanged = item?.url != lastAnnouncedURL
                    let meta = ICYMetadata.block(for: item, trackChanged: trackChanged)
                    let ok = await send(data: meta, on: connection)
                    if !ok { return }
                    if trackChanged { lastAnnouncedURL = item?.url }

                    bytesSinceMetaBlock = 0
                }
            }
        }

        _ = ownerRef()   // keep the reference alive through the closure
    }

    /// Scans the request-header bytes for `Icy-MetaData: 1` (case-insensitive).
    /// We only care about a single boolean, so no full HTTP parser needed.
    nonisolated static func headerRequestsICYMetadata(_ bytes: Data) -> Bool {
        guard let text = String(data: bytes, encoding: .utf8) else { return false }
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalised.split(separator: "\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("icy-metadata:") {
                let value = lower.dropFirst("icy-metadata:".count)
                    .trimmingCharacters(in: .whitespaces)
                if value == "1" { return true }
            }
        }
        return false
    }

    /// Build the HTTP response head. When ICY metadata is requested we
    /// advertise `icy-metaint`, the station name, and a genre — VLC shows
    /// `icy-name` in its "Current Media" panel.
    nonisolated static func buildResponseHeader(
        wantsMetadata: Bool,
        stationName: String
    ) -> String {
        if wantsMetadata {
            return """
            HTTP/1.1 200 OK\r
            Content-Type: audio/aac\r
            icy-metaint: \(ICYMetadata.blockInterval)\r
            icy-name: \(stationName)\r
            icy-genre: Ratbat Radio\r
            Cache-Control: no-cache\r
            Connection: close\r
            Pragma: no-cache\r
            \r

            """
        } else {
            return """
            HTTP/1.1 200 OK\r
            Content-Type: audio/aac\r
            Cache-Control: no-cache\r
            Connection: close\r
            Pragma: no-cache\r
            \r

            """
        }
    }

    /// Read until the `\r\n\r\n` header terminator and return EVERYTHING
    /// received — including any body bytes the client coalesced into the
    /// same segment (browsers and Cloudflare's tunnel do this routinely).
    /// Truncating at the terminator here silently discarded those bytes,
    /// which left `readBody` blocking on a receive that never fired: every
    /// real-world `POST /like` and `/skip` hung forever. `bodyBytes(after:)`
    /// is the designated way to peel the body back off this buffer.
    nonisolated static func readUntilHeaderEnd(
        connection: NWConnection,
        cap: Int = 4096
    ) async -> Data {
        var acc = Data()
        while acc.count < cap {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 512
                ) { data, _, _, _ in
                    cont.resume(returning: data)
                }
            }
            guard let chunk, !chunk.isEmpty else { return acc }
            acc.append(chunk)
            if acc.range(of: Data("\r\n\r\n".utf8)) != nil {
                return acc
            }
        }
        return acc
    }

    nonisolated static func send(data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    cont.resume(returning: error == nil)
                }
            )
        }
    }

    // MARK: - Encode loop (detached)

    nonisolated private static func runEncodeLoop(
        source: TrackSource,
        stationID: Station.ID,
        stationName: String,
        buffer: AACRingBuffer,
        bitrate: Int,
        sampleRate: Double,
        recordPlayThrough: (@Sendable (Int64) async -> Void)?,
        pipelineToken: UUID,
        owner: RadioBroadcaster?
    ) async {
        // `Thread.isMainThread` is unavailable from async contexts, so
        // ask pthread directly.
        Self.encodeLoopThreadObserver?(pthread_main_np() != 0)
        let decoder = AudioDecoder()
        let log = Logger(
            subsystem: RatbatLog.subsystem,
            category: "broadcaster.encode"
        )

        let encoder: AACEncoder
        do {
            encoder = try AACEncoder(
                inputFormat: AudioDecoder.outputFormat,
                sampleRate: sampleRate,
                bitrate: bitrate
            )
        } catch {
            log.error("encoder init failed: \(String(describing: error), privacy: .public)")
            if let owner {
                await MainActor.run {
                    owner.error = "Encoder init failed: \(error.localizedDescription)"
                }
            }
            return
        }

        // Track-index flag used to gate listener-presence idling: the first
        // track always resolves unconditionally so the station feels
        // responsive when the user clicks Start Broadcast, but subsequent
        // tracks only resolve while at least one listener is connected.
        var trackIndex = 0

        // Wall-clock pacing: the instant at which the audio written so far
        // would finish playing. Anchored on the first chunk and re-anchored
        // whenever the loop falls behind, so an idle gate or a slow source
        // never leaves a debt for the encoder to sprint off. See the pacing
        // block at the bottom of the inner loop.
        var playoutHead = Self.monotonicSeconds()

        // One-track-ahead prefetch. Generative sources resolve + download
        // via yt-dlp inside `nextURL()` (and occasionally run a slow pool
        // refill); doing that inline at the track boundary stalled the
        // encode loop and drained the ring buffer, so listeners heard a
        // gap every few tracks. We instead kick off the NEXT track's
        // resolve while the CURRENT one plays out, hiding the latency
        // behind ~minutes of audio. At most one fetch is ever in flight;
        // it's cancelled on loop exit.
        var prefetch: Task<TrackSourceItem?, Error>?
        // Run-length of back-to-back failed opens, reset on any success.
        var consecutiveOpenFailures = 0
        // Same, for source errors. Separate because they are separate
        // faults: one means the library is unreadable, the other that the
        // resolver or network is. Only one can fire per iteration, so
        // their delays never compound within a single pass.
        var consecutiveSourceErrors = 0
        // Why this loop ended. Overwritten by the two `break` paths below;
        // staying `.cancelled` means the task was torn down from outside.
        var exitReason: OffAirReason = .cancelled

        // Outer loop: pull items until the source is exhausted or the
        // task is cancelled. Inner loop: pump PCM → AAC → ring buffer
        // for the currently open item.
        outer: while !Task.isCancelled {
            // Data-conscious idle. After the first track, hold here until
            // someone is listening — the resolver + transient cache are
            // both costly and pointless with nobody tuned in. The station
            // stays ON AIR in the UI either way; only the encode loop
            // sleeps. A new listener connection unblocks this within ~5s.
            if trackIndex > 0 {
                await Self.awaitListener(stationID: stationID, owner: owner, log: log)
                if Task.isCancelled { break }
            }

            // Take the prefetched item if one's in flight; otherwise
            // (first track only) resolve synchronously — the user just hit
            // play and expects the station to come alive promptly.
            let nextItem: TrackSourceItem?
            do {
                if let prefetch {
                    nextItem = try await prefetch.value
                } else {
                    nextItem = try await source.nextURL()
                }
            } catch is CancellationError {
                exitReason = .cancelled
                break
            } catch {
                // Retry rather than fold.
                //
                // This `break` used to end the station for ANY thrown
                // error, and the generative controllers laundered network
                // failures into `poolExhausted` -> nil -> the same fate.
                // A blip lasting seconds took a station off air until the
                // next launch. Genuine exhaustion still arrives as `nil`
                // and still ends the station, just below.
                consecutiveSourceErrors += 1
                let backoff = Self.sourceErrorBackoff(
                    consecutiveFailures: consecutiveSourceErrors
                )
                log.error(
                    "source error on \(stationName, privacy: .public) (\(consecutiveSourceErrors, privacy: .public) in a row): \(String(describing: error), privacy: .public); retrying in \(backoff, privacy: .public)s"
                )
                if let owner {
                    await MainActor.run {
                        owner.recordSourceRetry(
                            stationID: stationID,
                            attempt: consecutiveSourceErrors,
                            reason: String(describing: error)
                        )
                    }
                }
                prefetch = nil
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                continue outer
            }
            prefetch = nil

            guard let item = nextItem else {
                // `.notice`, not `.info`: the unified log does not persist
                // info-level messages, so the only record of a station
                // running dry overnight evaporated before anyone looked.
                log.notice(
                    "station off air: \(stationName, privacy: .public) reason=exhausted trackIndex=\(trackIndex, privacy: .public)"
                )
                exitReason = .exhausted
                break
            }
            trackIndex += 1
            // Got an item: whatever was wrong with the source has passed.
            consecutiveSourceErrors = 0
            if owner != nil { await MainActor.run { owner?.clearSourceRetry(stationID: stationID) } }

            do {
                try decoder.open(url: item.url)
                let label = item.title ?? item.url.lastPathComponent
                log.info("decoding \(label, privacy: .public)")
                // Read embedded cover art here, on the detached loop, while
                // the file is already warm — a generative track carries a
                // remote thumbnail URL instead and needs no probe.
                let artwork: Data? = item.artworkURL == nil
                    ? await TrackFileProbe.artworkJPEG(of: item.url)
                    : nil
                // The file the listener is about to hear is the only
                // unimpeachable source for how long it runs.
                let measured = decoder.duration
                if let owner {
                    await MainActor.run {
                        owner.updateCurrentItem(
                            item,
                            artwork: artwork,
                            measuredDuration: measured,
                            stationID: stationID
                        )
                    }
                }
            } catch {
                let label = item.title ?? item.url.lastPathComponent
                log.error("open failed for \(label, privacy: .public) at \(item.url.path, privacy: .public): \(String(describing: error), privacy: .public)")

                // Throttle sustained failure. Without this the loop went
                // straight back round with no delay: with a listener
                // attached `awaitListener` returns instantly, so an
                // unreadable library (unmounted volume, moved folder) span
                // as fast as the CPU allowed — pegging a core and writing
                // a fabricated history row per iteration, because
                // `PlaylistSource.nextURL` records the play before the
                // file is opened. Measured at >10,000 rows in 3 seconds.
                consecutiveOpenFailures += 1
                let backoff = Self.openFailureBackoff(
                    consecutiveFailures: consecutiveOpenFailures
                )
                if backoff > 0 {
                    log.error(
                        "\(consecutiveOpenFailures, privacy: .public) consecutive open failures on \(stationName, privacy: .public); backing off \(backoff, privacy: .public)s"
                    )
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
                continue outer
            }
            // Opened cleanly — this run of failures is over.
            consecutiveOpenFailures = 0

            // Resolve the NEXT track now, concurrently with this track's
            // playout (~minutes), so its yt-dlp download or pool refill is
            // already done by the time the inner loop drains — no boundary
            // stall. The `awaitListener` gate at the top of the loop still
            // bounds us to at most one track prefetched while nobody's
            // tuned in, preserving the data-conscious idle.
            prefetch = Task { try await source.nextURL() }
            // Publish the resolved next track for /now.json — Task.value
            // is multi-awaitable, so this observer doesn't consume the
            // result the loop itself will take at the boundary.
            if let owner, let watchedPrefetch = prefetch {
                Task { [weak owner] in
                    // `try?` flattens the Task's `TrackSourceItem?` success
                    // value with its own optionality (SE-0230) — one bind.
                    guard let upcoming = try? await watchedPrefetch.value else { return }
                    await MainActor.run { [weak owner] in
                        owner?.updateUpcoming(upcoming, stationID: stationID)
                    }
                }
            }

            var playedThrough = false
            while !Task.isCancelled {
                // User-initiated skip? Break the inner loop so the outer
                // loop pulls the next item. The discontinuity mark below
                // cuts the buffered backlog, so listeners hear the switch
                // within their browser's own buffer (~2-5s), not after
                // draining the ring.
                if let owner {
                    let skip = await MainActor.run { owner.consumeSkipRequest(stationID: stationID) }
                    if skip {
                        // Deliberate rejection: cut the buffered backlog so
                        // listeners jump to the new track in a beat instead
                        // of draining the ring of audio they just skipped.
                        // The browser's own buffer is the only remaining lag.
                        buffer.markDiscontinuity()
                        // The backlog that was the listener's runway is gone,
                        // so the playout head is *now*. Without this the
                        // encoder would think it was still a lead ahead and
                        // sleep through the first seconds of the new track —
                        // silence, exactly where the point was to cut it.
                        playoutHead = Self.monotonicSeconds()
                        break
                    }
                }
                guard let pcm = decoder.readNextBuffer() else {
                    playedThrough = true
                    break   // EOF — advance to next item
                }
                // Measured off the buffer rather than assumed: the decoder
                // reads a fixed frame count in the *source* file's sample
                // rate, so one chunk of a 48 kHz file is not the same amount
                // of time as one chunk of a 44.1 kHz file.
                let chunkSeconds = pcm.format.sampleRate > 0
                    ? Double(pcm.frameLength) / pcm.format.sampleRate
                    : 0
                do {
                    if let encoded = try encoder.encode(pcm) {
                        buffer.write(encoded)
                    }
                } catch {
                    log.error("encode failed: \(String(describing: error), privacy: .public)")
                    break
                }

                // Pace against a wall clock, not a fixed sleep.
                //
                // This used to sleep a flat 70 ms per ~93 ms chunk, "to stay
                // ~1 chunk ahead". That is not a lead, it is a 1.2–1.3x
                // overfeed, and it compounds: measured against the live
                // station, 37.1s of audio left the encoder every 30.1s of
                // wall clock. A listener's buffer therefore grew by ~14s for
                // every minute they stayed tuned in, so how far the audio
                // ran behind /now.json depended on how long they had been
                // listening — a moving target no fixed delay in the client
                // can correct for, and eventually far enough behind that the
                // ring lapped the reader and dropped audio outright.
                //
                // Writing only up to `broadcastLeadSeconds` past the playout
                // head keeps the runway constant and knowable instead.
                let paced = Self.pace(
                    playoutHead: playoutHead,
                    now: Self.monotonicSeconds(),
                    chunkSeconds: chunkSeconds,
                    lead: Self.broadcastLeadSeconds
                )
                playoutHead = paced.head
                if paced.sleep > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(paced.sleep * 1_000_000_000))
                }
            }

            decoder.close()

            // A track that drained all the way to EOF — rather than being
            // skipped or aborted by an encode error — counts as a full
            // play-through, the strongest positive taste signal we get.
            // Feed it back so the profile can weight tracks the user lets
            // run against ones they skip. Playlist items carry no historyID,
            // so this is naturally a no-op for non-generative stations.
            if playedThrough, let historyID = item.historyID {
                await recordPlayThrough?(historyID)
            }
        }

        // Drop any in-flight prefetch so a dangling resolve (and its
        // yt-dlp subprocess await) doesn't outlive the loop.
        prefetch?.cancel()
        decoder.close()
        if let owner {
            await MainActor.run {
                owner.updateCurrentItem(nil, stationID: stationID)
                // When the source runs dry (or the loop exits for any
                // non-cancellation reason), fold the pipeline down so the
                // UI reflects reality and the listener can cycle. A
                // cancellation-driven exit has already mutated the state
                // from the main actor, so this is a no-op in that case.
                // Identity, not just station: only fold down the
                // pipeline this loop actually owns. Without the token a
                // zombie loop unwinding late tore down whatever had
                // replaced it, which silently undid the owner's restart.
                if owner.broadcasting.contains(stationID),
                   owner.pipelines[stationID]?.token == pipelineToken {
                    // Running dry is not the owner saying "stop". Reaching
                    // here means the loop exited on its own; a deliberate
                    // stop has already cleared `broadcasting`, so the guard
                    // above is false and this never fires for one. Forgetting
                    // the slug here would delete the station's live intent,
                    // and since `RootView` resumes from
                    // `autoStartSlugs ∪ lastLiveSlugs` once per launch, a
                    // station that starved overnight would be silently gone
                    // after the next restart — indistinguishable from the
                    // owner having turned it off.
                    owner.recordOffAir(
                        stationID: stationID,
                        reason: exitReason,
                        trackIndex: trackIndex
                    )
                    owner.stopBroadcastRanDry(stationID: stationID)
                }
            }
        }
        log.notice(
            "encode loop exiting: \(stationName, privacy: .public) reason=\(exitReason.label, privacy: .public) trackIndex=\(trackIndex, privacy: .public)"
        )
    }

    /// Block until at least one listener is connected to `stationID`, polling
    /// `listenerCount` every 5s. Returns immediately when already ≥1, or when
    /// the task is cancelled. Logs one line on entering idle and one on
    /// resuming, so long idles are visible in the OSLog stream.
    nonisolated private static func awaitListener(
        stationID: Station.ID,
        owner: RadioBroadcaster?,
        log: Logger
    ) async {
        let initial = await MainActor.run { owner?.listenerCount[stationID] ?? 0 }
        if initial > 0 { return }

        let shortID = stationID.uuidString.prefix(8)
        log.info("idling \(shortID, privacy: .public) — no listeners, will resume on connect")

        // Signal, not poll. This was a 5-second polling sleep, so the
        // first listener on an idle station — the normal state of a
        // personal radio — waited 0–5s before a single byte moved.
        // `registerClient` now wakes us the moment a client attaches, and
        // teardown/cancellation wake us too so the task cannot be stranded.
        guard let owner else { return }
        await owner.awaitFirstListener(stationID: stationID)
        if Task.isCancelled { return }
        let count = await MainActor.run { owner.listenerCount[stationID] }
        log.info("resuming \(shortID, privacy: .public) — \(count ?? 0, privacy: .public) listener(s)")
    }
}
