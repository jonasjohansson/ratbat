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
        let youtubeURL: String?
        let sourceURL: String?
    }
    /// Newest-first, capped at 5. In-memory on purpose: uniform across
    /// station kinds (playlist tracks have no history rows) and reset on
    /// restart, which is the honest lifetime for "what just played".
    private(set) var recentByStation: [Station.ID: [RecentTrack]] = [:]

    /// Provenance for the CURRENT track, resolved once per track change
    /// from its history row (YouTube id → watch URL; Bandcamp release /
    /// NTS show URL). nil for playlist tracks and while the lookup runs.
    private var provenanceByStation: [Station.ID: (youtube: String?, source: String?)] = [:]

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
    nonisolated public static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Config

    private let port: NWEndpoint.Port
    private let preferences: BroadcastPreferences
    private var preferencesSubscription: AnyCancellable?

    /// Failed-attempt throttle state for ``ownerGate(_:)``. The three
    /// knobs are `var`s rather than constants only so the tests that
    /// deliberately hammer the guest path can zero the delay and stay
    /// fast — production never assigns them.
    private(set) var failedOwnerAttempts = 0
    var ownerFreeAttempts = 3
    var ownerThrottleStep: TimeInterval = 0.5
    var ownerThrottleCeiling: TimeInterval = 5
    private let logger = Logger(
        subsystem: "se.jonasjohansson.ratbat",
        category: "broadcaster"
    )

    #if os(macOS)
    /// Optional NTS-stack dependencies. `nil` in test / minimal-init
    /// configurations; an attempt to broadcast an NTS station without
    /// these wired up logs an error and bails instead of crashing.
    private let downloadService: DownloadService?
    private let nts: NTSClient?
    private let history: HistoryStore?
    /// Read-side handle on the user's music folder. Used by the ♥ save
    /// flow to know where to copy cached files. `nil` in test configs;
    /// `handleLike` returns a 500 when it's missing.
    private let libraryConfig: LibraryConfig?
    /// Locally-derived taste signals shared across every generative
    /// station. Optional so minimal-init tests can skip it — stations
    /// built without a profile just get an empty profile's zero-valued
    /// scores, which degrades to near-random selection rather than
    /// crashing.
    private let tasteProfile: TasteProfile?
    /// Long-lived MusicBrainz client shared across every Last.fm /
    /// Bandcamp station so the per-artist / per-recording caches
    /// accumulate across pool refills and across stations. Eagerly
    /// constructed at broadcaster init — the constructor makes no
    /// network calls, so the cost is negligible, and eager init
    /// removes a benign TOCTOU race between two concurrent
    /// `startBroadcast` calls both lazy-initing the shared client.
    private let musicBrainz: MusicBrainzClient
    /// Long-lived Bandcamp discover client. Same rationale as
    /// ``musicBrainz``: per-actor request throttling is more useful
    /// when the throttle gate survives across stations / refills,
    /// and the constructor is network-free so eager init is free.
    private let bandcamp: BandcampClient
    #endif

    // MARK: - Internals

    /// Per-station encode/serve state. Non-Sendable because it's always
    /// accessed from the main actor; the detached tasks inside only hold
    /// weak refs to the broadcaster and reach back through `MainActor.run`.
    private final class BroadcastPipeline {
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

        init(station: Station, buffer: AACRingBuffer, bitrate: Int, sampleRate: Double) {
            self.station = station
            self.buffer = buffer
            self.bitrate = bitrate
            self.sampleRate = sampleRate
        }
    }

    private var pipelines: [Station.ID: BroadcastPipeline] = [:]
    /// Display names for every station the user has saved, live or not —
    /// see ``registerStations(_:)``. Absent id means "we have never heard
    /// of this station", which is how `/history` distinguishes a deleted
    /// station from one that simply isn't on air.
    private var stationNames: [Station.ID: String] = [:]
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
            let source = PlaylistSource(tracks: queue, recordPlay: recorder)
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
            tasteProfile: profile
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
            tasteProfile: profile
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
            tasteProfile: profile
        )
        return BandcampSource(controller: controller)
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

        // Bring up the shared listener the first time anyone broadcasts.
        if listener == nil {
            do {
                try startHTTPServer()
            } catch {
                self.error = "Listener failed to start: \(error.localizedDescription)"
                logger.error("listener start failed: \(String(describing: error))")
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
            buffer: AACRingBuffer(),
            bitrate: bitrate,
            sampleRate: sampleRate
        )
        pipelines[station.id] = pipeline
        // A station we are broadcasting is one we can always name, even if
        // nobody registered the catalogue (older callers, tests).
        stationNames[station.id] = station.name
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
                owner: self
            )
        }

        #if os(macOS)
        // First-station bootstrap for the tunnel. `CloudflareTunnel.start`
        // is idempotent, but gating on count avoids spurious log churn.
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
    private func stopBroadcast(stationID: Station.ID, forgetLive: Bool) {
        guard let pipeline = pipelines[stationID] else { return }
        if forgetLive {
            preferences.forgetLive(slug: pipeline.station.slug)
        }

        pipeline.encodeTask?.cancel()
        pipelines.removeValue(forKey: stationID)
        broadcasting.remove(stationID)
        listenerCount.removeValue(forKey: stationID)
        currentItemByStation.removeValue(forKey: stationID)
        upcomingByStation.removeValue(forKey: stationID)
        recentByStation.removeValue(forKey: stationID)
        provenanceByStation.removeValue(forKey: stationID)

        // Boot any clients still attached to this station.
        let toRemove = clients.filter { $0.value.stationID == stationID }
        for (id, entry) in toRemove {
            clientTasks[id]?.cancel()
            clientTasks.removeValue(forKey: id)
            entry.connection.cancel()
            clients.removeValue(forKey: id)
        }

        if broadcasting.isEmpty {
            tearDownListener()
        }

        logger.info("station broadcast stopped: \(pipeline.station.slug, privacy: .public)")
    }

    /// Stop every running broadcast and tear the listener down. Idempotent.
    /// Keeps the last-live record intact — this is the shutdown/restart-all
    /// gesture, and the next launch should resume what was playing.
    public func stopAll() {
        for id in Array(pipelines.keys) {
            stopBroadcast(stationID: id, forgetLive: false)
        }
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
        for station in stations {
            stationNames[station.id] = station.name
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
    fileprivate func updateCurrentItem(_ item: TrackSourceItem?, stationID: Station.ID) {
        // Retire the outgoing track into the recent ring, carrying
        // whatever provenance had resolved for it. Newest first, cap 5.
        if let outgoing = currentItemByStation[stationID] {
            let prov = provenanceByStation[stationID]
            var ring = recentByStation[stationID] ?? []
            ring.insert(RecentTrack(
                entryID: UUID(),
                item: outgoing,
                playedAt: Date(),
                youtubeURL: prov?.youtube,
                sourceURL: prov?.source
            ), at: 0)
            if ring.count > 5 { ring.removeLast(ring.count - 5) }
            recentByStation[stationID] = ring
        }
        provenanceByStation.removeValue(forKey: stationID)
        // The prefetched "next" either just became current or was skipped
        // past — either way it's stale until the loop re-publishes.
        upcomingByStation.removeValue(forKey: stationID)
        if let item {
            currentItemByStation[stationID] = item
        } else {
            currentItemByStation.removeValue(forKey: stationID)
        }
        // A track change is exactly what /events subscribers are waiting
        // for — push the fresh now-playing snapshot.
        pushSSE()

        #if os(macOS)
        // Resolve the incoming track's provenance from its history row —
        // one actor hop per track change, cached until the next change,
        // re-pushed over SSE when it lands.
        if let item, let historyID = item.historyID, let history {
            Task { [weak self] in
                guard let entry = try? await history.entry(id: historyID) else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.currentItemByStation[stationID]?.historyID == historyID else { return }
                    self.provenanceByStation[stationID] = (
                        entry.youtubeID.map { "https://www.youtube.com/watch?v=\($0)" },
                        entry.sourceShowURL?.absoluteString
                    )
                    self.pushSSE()
                }
            }
        }
        #endif
    }

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
                case .failed(let err):
                    self.error = "Listener failed: \(err.localizedDescription)"
                    self.logger.error("listener failed: \(String(describing: err), privacy: .public)")
                    self.stopAll()
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

        let port = self.port.rawValue
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
        let authHandler: @Sendable (String?) async -> (Int, Data) = { [weak self] token in
            await self?.performAuthAsync(token: token)
                ?? (500, Data("{\"status\":\"error\",\"message\":\"no broadcaster\"}".utf8))
        }
        let likeHandler: @Sendable (UUID, String?) async -> (Int, Data) = { [weak self] stationID, token in
            // Hop to the main actor to resolve the pipeline snapshot,
            // then do the copy + history mark off-main without pinning
            // the UI thread. `performLikeAsync` is the async bridge.
            await self?.performLikeAsync(stationID: stationID, token: token)
                ?? (500, Data("{\"status\":\"error\",\"message\":\"no broadcaster\"}".utf8))
        }
        let retroLikeHandler: @Sendable (UUID, String, String?) async -> (Int, Data) = { [weak self] stationID, entryID, token in
            await self?.performRetroLikeAsync(stationID: stationID, entryID: entryID, token: token)
                ?? (500, Data("{\"status\":\"error\",\"message\":\"no broadcaster\"}".utf8))
        }
        let skipHandler: @Sendable (UUID, String?) async -> (Int, Data) = { [weak self] stationID, token in
            // 👎 from a listener — mark the current track skipped and nudge
            // the encode loop. `performSkipAsync` is the main-actor bridge.
            await self?.performSkipAsync(stationID: stationID, token: token)
                ?? (500, Data("{\"status\":\"error\",\"message\":\"no broadcaster\"}".utf8))
        }
        let nextHandler: @Sendable (UUID, String?) async -> (Int, Data) = { [weak self] stationID, token in
            // ⏭ — advance without judging. No taste signal, no history
            // mark; "not right now" mustn't poison the profile the way
            // 👎 deliberately does.
            await self?.performNextAsync(stationID: stationID, token: token)
                ?? (500, Data("{\"status\":\"error\",\"message\":\"no broadcaster\"}".utf8))
        }
        let boostHandler: @Sendable (UUID, String?) async -> (Int, Data) = { [weak self] stationID, token in
            // Boost — "more of this": the strong steering signal, above ♥.
            await self?.performBoostAsync(stationID: stationID, token: token)
                ?? (500, Data("{\"status\":\"error\",\"message\":\"no broadcaster\"}".utf8))
        }
        let unlikeHandler: @Sendable (UUID, String?) async -> (Int, Data) = { [weak self] stationID, token in
            // Un-♥ — a mis-tap shouldn't be forever: clears the signal and
            // removes the file the ♥ copied (never a library original).
            await self?.performUnlikeAsync(stationID: stationID, token: token)
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
            if method == "OPTIONS" && (path == "/auth" || path == "/like" || path == "/skip" || path == "/next" || path == "/boost" || path == "/unlike") {
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

            // Passcode check for the web player's unlock prompt. Answers
            // 200 or 403 and changes nothing either way, so the prompt can
            // tell the owner they mistyped without ♥-ing a track to find
            // out. Shares the throttle with the action endpoints.
            if method == "POST" && path == "/auth" {
                let contentLength = Self.contentLength(from: headerBytes) ?? 0
                let body = await Self.readBody(
                    connection: connection,
                    alreadyRead: Self.bodyBytes(after: headerBytes),
                    expected: contentLength
                )
                let token = (try? JSONDecoder().decode(AuthRequest.self, from: body))?.token
                let (status, payload) = await authHandler(token)
                var headers = Self.corsHeaders()
                headers["Content-Type"] = "application/json"
                _ = await Self.send(
                    data: Self.buildHTTPResponse(status: status, headers: headers, body: payload),
                    on: connection
                )
                connection.cancel()
                return
            }

            // ♥ save — move the currently-playing cached file into the
            // user's library. Only meaningful on macOS (broadcaster is
            // macOS-only), but the request surface is cross-platform.
            if method == "POST" && path == "/like" {
                let contentLength = Self.contentLength(from: headerBytes) ?? 0
                let body = await Self.readBody(
                    connection: connection,
                    alreadyRead: Self.bodyBytes(after: headerBytes),
                    expected: contentLength
                )
                guard let req = try? JSONDecoder().decode(LikeRequest.self, from: body),
                      let stationID = UUID(uuidString: req.station) else {
                    var headers = Self.corsHeaders()
                    headers["Content-Type"] = "application/json"
                    _ = await Self.send(
                        data: Self.buildHTTPResponse(
                            status: 400,
                            headers: headers,
                            body: Data("{\"status\":\"error\",\"message\":\"bad request\"}".utf8)
                        ),
                        on: connection
                    )
                    connection.cancel()
                    return
                }

                let (status, payload) = if let entry = req.entry {
                    await retroLikeHandler(stationID, entry, req.token)
                } else {
                    await likeHandler(stationID, req.token)
                }
                var headers = Self.corsHeaders()
                headers["Content-Type"] = "application/json"
                _ = await Self.send(
                    data: Self.buildHTTPResponse(status: status, headers: headers, body: payload),
                    on: connection
                )
                connection.cancel()
                return
            }

            // 👎 skip — listener-side thumbs-down on the current track.
            // Same request shape and CORS handling as /like; marks the
            // track skipped (taste blacklist) and advances the station.
            if method == "POST" && path == "/skip" {
                let contentLength = Self.contentLength(from: headerBytes) ?? 0
                let body = await Self.readBody(
                    connection: connection,
                    alreadyRead: Self.bodyBytes(after: headerBytes),
                    expected: contentLength
                )
                guard let req = try? JSONDecoder().decode(LikeRequest.self, from: body),
                      let stationID = UUID(uuidString: req.station) else {
                    var headers = Self.corsHeaders()
                    headers["Content-Type"] = "application/json"
                    _ = await Self.send(
                        data: Self.buildHTTPResponse(
                            status: 400,
                            headers: headers,
                            body: Data("{\"status\":\"error\",\"message\":\"bad request\"}".utf8)
                        ),
                        on: connection
                    )
                    connection.cancel()
                    return
                }

                let (status, payload) = await skipHandler(stationID, req.token)
                var headers = Self.corsHeaders()
                headers["Content-Type"] = "application/json"
                _ = await Self.send(
                    data: Self.buildHTTPResponse(status: status, headers: headers, body: payload),
                    on: connection
                )
                connection.cancel()
                return
            }

            // ⏭ next — advance the station without recording any taste
            // signal. Same request shape and CORS handling as /like.
            if method == "POST" && path == "/next" {
                let contentLength = Self.contentLength(from: headerBytes) ?? 0
                let body = await Self.readBody(
                    connection: connection,
                    alreadyRead: Self.bodyBytes(after: headerBytes),
                    expected: contentLength
                )
                guard let req = try? JSONDecoder().decode(LikeRequest.self, from: body),
                      let stationID = UUID(uuidString: req.station) else {
                    var headers = Self.corsHeaders()
                    headers["Content-Type"] = "application/json"
                    _ = await Self.send(
                        data: Self.buildHTTPResponse(
                            status: 400,
                            headers: headers,
                            body: Data("{\"status\":\"error\",\"message\":\"bad request\"}".utf8)
                        ),
                        on: connection
                    )
                    connection.cancel()
                    return
                }

                let (status, payload) = await nextHandler(stationID, req.token)
                var headers = Self.corsHeaders()
                headers["Content-Type"] = "application/json"
                _ = await Self.send(
                    data: Self.buildHTTPResponse(status: status, headers: headers, body: payload),
                    on: connection
                )
                connection.cancel()
                return
            }

            // Boost / un-♥ — same request shape and CORS handling as /like.
            if method == "POST" && (path == "/boost" || path == "/unlike") {
                let contentLength = Self.contentLength(from: headerBytes) ?? 0
                let body = await Self.readBody(
                    connection: connection,
                    alreadyRead: Self.bodyBytes(after: headerBytes),
                    expected: contentLength
                )
                guard let req = try? JSONDecoder().decode(LikeRequest.self, from: body),
                      let stationID = UUID(uuidString: req.station) else {
                    var headers = Self.corsHeaders()
                    headers["Content-Type"] = "application/json"
                    _ = await Self.send(
                        data: Self.buildHTTPResponse(
                            status: 400,
                            headers: headers,
                            body: Data("{\"status\":\"error\",\"message\":\"bad request\"}".utf8)
                        ),
                        on: connection
                    )
                    connection.cancel()
                    return
                }

                let (status, payload) = path == "/boost"
                    ? await boostHandler(stationID, req.token)
                    : await unlikeHandler(stationID, req.token)
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
            if path.hasPrefix("/history") {
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
                _ = await Self.send(data: Self.sseEvent(await nowPayload()), on: connection)
                // Heartbeat loop. Pushes are driven from the broadcaster;
                // this only keeps the pipe warm and notices a dead peer.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if Task.isCancelled { break }
                    let alive = await Self.send(data: Data(": heartbeat\n\n".utf8), on: connection)
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
        clientTasks[ObjectIdentifier(connection)] = task
    }

    private func registerClient(_ connection: NWConnection, stationID: Station.ID) {
        let id = ObjectIdentifier(connection)
        clients[id] = (connection, stationID)
        listenerCount[stationID, default: 0] += 1
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
        let event = Self.sseEvent(buildNowPayload())
        for (id, conn) in sseSubscribers {
            Task { [weak self] in
                let ok = await Self.send(data: event, on: conn)
                if !ok { await MainActor.run { self?.removeSSE(id) } }
            }
        }
    }

    /// Frame a JSON payload as a single SSE `data:` event. SSE is
    /// line-oriented and terminates an event with a blank line; our payload
    /// is single-line JSON so one `data:` line suffices.
    nonisolated static func sseEvent(_ json: Data) -> Data {
        var out = Data("data: ".utf8)
        out.append(json)
        out.append(Data("\n\n".utf8))
        return out
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
    nonisolated static func readBody(
        connection: NWConnection,
        alreadyRead: Data,
        expected: Int
    ) async -> Data {
        var acc = alreadyRead
        let deadline = Date().addingTimeInterval(3)
        while acc.count < expected, Date() < deadline {
            let needed = expected - acc.count
            // The deadline above only bounds the loop BETWEEN receives —
            // `connection.receive` itself never times out, so a client
            // that promises Content-Length bytes and goes quiet would
            // park this task forever. The watchdog cancels the connection
            // instead, which forces the pending receive to complete.
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
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
        case 204: statusText = "No Content"
        case 302: statusText = "Found"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 409: statusText = "Conflict"
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
    /// scoring term weighted above ♥-saves. No refill is forced: the next
    /// natural refill steers, which also debounces rapid boosts for free.
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
                try c.encodeIfPresent(youtubeURL, forKey: .youtubeURL)
                try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
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
                youtubeURL: row.youtubeID.map { "https://www.youtube.com/watch?v=\($0)" },
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

    private func buildNowPayload() -> Data {
        struct NowStation: Encodable {
            let id: String
            let name: String
            let slug: String
            let broadcasting: Bool
            let streamURL: String?
            let listeners: Int
            let currentTrack: NowTrack?
            let recent: [RecentPayload]
            let nextTrack: NextPayload?
        }
        struct NowTrack: Encodable {
            let title: String
            let artist: String
            let album: String
            let youtubeURL: String?
            let sourceURL: String?
        }
        struct RecentPayload: Encodable {
            let entryID: String
            let title: String
            let artist: String
            let playedAt: Double
            let youtubeURL: String?
            let sourceURL: String?
        }
        struct NextPayload: Encodable {
            let title: String
            let artist: String
        }
        struct NowResponse: Encodable {
            let stations: [NowStation]
        }

        // Stable ordering by station name so UI doesn't jitter between
        // polls. Dictionary iteration isn't deterministic in Swift.
        let ordered = pipelines.values.sorted { $0.station.name < $1.station.name }
        let stations: [NowStation] = ordered.map { pipeline in
            let stationID = pipeline.station.id
            let item = currentItemByStation[stationID]
            let listeners = listenerCount[stationID] ?? 0
            let prov = provenanceByStation[stationID]
            // `NowTrack.album` kept for UI backwards compat, but TrackSource
            // items don't carry album metadata — empty string is fine.
            return NowStation(
                id: stationID.uuidString,
                name: pipeline.station.name,
                slug: pipeline.station.slug,
                broadcasting: true,
                streamURL: "/stream/\(pipeline.station.slug).aac",
                listeners: listeners,
                currentTrack: item.map {
                    NowTrack(
                        title: $0.title ?? "",
                        artist: $0.artist ?? "",
                        album: "",
                        youtubeURL: prov?.youtube,
                        sourceURL: prov?.source
                    )
                },
                recent: (recentByStation[stationID] ?? []).map {
                    RecentPayload(
                        entryID: $0.entryID.uuidString,
                        title: $0.item.title ?? "",
                        artist: $0.item.artist ?? "",
                        playedAt: $0.playedAt.timeIntervalSince1970,
                        youtubeURL: $0.youtubeURL,
                        sourceURL: $0.sourceURL
                    )
                },
                nextTrack: upcomingByStation[stationID].map {
                    NextPayload(title: $0.title ?? "", artist: $0.artist ?? "")
                }
            )
        }

        let response = NowResponse(stations: stations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(response)) ?? Data("{\"stations\":[]}".utf8)
    }

    // MARK: - Client serving (detached)

    /// Reads were already done in `routeIncoming`; this writes the 200
    /// header and pumps the pipeline's ring buffer to the client. ICY
    /// metadata (if requested) is injected every 16384 bytes using the
    /// station's current track.
    private static func serveClient(
        connection: NWConnection,
        buffer: AACRingBuffer,
        stationID: Station.ID,
        stationName: String,
        wantsMetadata: Bool,
        ownerRef: @escaping @Sendable () -> RadioBroadcaster?
    ) async {
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

    private static func runEncodeLoop(
        source: TrackSource,
        stationID: Station.ID,
        stationName: String,
        buffer: AACRingBuffer,
        bitrate: Int,
        sampleRate: Double,
        recordPlayThrough: (@Sendable (Int64) async -> Void)?,
        owner: RadioBroadcaster?
    ) async {
        let decoder = AudioDecoder()
        let log = Logger(
            subsystem: "se.jonasjohansson.ratbat",
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
            log.error("encoder init failed: \(String(describing: error))")
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

        // One-track-ahead prefetch. Generative sources resolve + download
        // via yt-dlp inside `nextURL()` (and occasionally run a slow pool
        // refill); doing that inline at the track boundary stalled the
        // encode loop and drained the ring buffer, so listeners heard a
        // gap every few tracks. We instead kick off the NEXT track's
        // resolve while the CURRENT one plays out, hiding the latency
        // behind ~minutes of audio. At most one fetch is ever in flight;
        // it's cancelled on loop exit.
        var prefetch: Task<TrackSourceItem?, Error>?

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
            } catch {
                log.error("source error: \(String(describing: error), privacy: .public)")
                break
            }
            prefetch = nil

            guard let item = nextItem else {
                log.info("source exhausted for \(stationName, privacy: .public)")
                break
            }
            trackIndex += 1

            do {
                try decoder.open(url: item.url)
                let label = item.title ?? item.url.lastPathComponent
                log.info("decoding \(label, privacy: .public)")
                if let owner {
                    await MainActor.run { owner.updateCurrentItem(item, stationID: stationID) }
                }
            } catch {
                let label = item.title ?? item.url.lastPathComponent
                log.error("open failed for \(label, privacy: .public) at \(item.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                continue outer
            }

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
                        // of draining ~8s of audio they just skipped. The
                        // browser's own buffer is the only remaining lag.
                        buffer.markDiscontinuity()
                        break
                    }
                }
                guard let pcm = decoder.readNextBuffer() else {
                    playedThrough = true
                    break   // EOF — advance to next item
                }
                do {
                    if let encoded = try encoder.encode(pcm) {
                        buffer.write(encoded)
                    }
                } catch {
                    log.error("encode failed: \(String(describing: error))")
                    break
                }

                // Rate-limit so we don't fill the ring buffer faster than
                // real time. At 44.1 kHz / 4096 frames-per-read, the
                // nominal wall-clock duration of one chunk is ~93 ms.
                // We sleep slightly less to stay ~1 chunk ahead.
                try? await Task.sleep(nanoseconds: 70_000_000)
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
                if owner.broadcasting.contains(stationID) {
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
                    owner.stopBroadcastRanDry(stationID: stationID)
                }
            }
        }
        log.info("encode loop exiting")
    }

    /// Block until at least one listener is connected to `stationID`, polling
    /// `listenerCount` every 5s. Returns immediately when already ≥1, or when
    /// the task is cancelled. Logs one line on entering idle and one on
    /// resuming, so long idles are visible in the OSLog stream.
    private static func awaitListener(
        stationID: Station.ID,
        owner: RadioBroadcaster?,
        log: Logger
    ) async {
        let initial = await MainActor.run { owner?.listenerCount[stationID] ?? 0 }
        if initial > 0 { return }

        let shortID = stationID.uuidString.prefix(8)
        log.info("idling \(shortID, privacy: .public) — no listeners, will resume on connect")
        let pollNanos: UInt64 = 5_000_000_000
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pollNanos)
            if Task.isCancelled { return }
            let count = await MainActor.run { owner?.listenerCount[stationID] ?? 0 }
            if count > 0 {
                log.info("resuming \(shortID, privacy: .public) — \(count, privacy: .public) listener(s)")
                return
            }
        }
    }
}
