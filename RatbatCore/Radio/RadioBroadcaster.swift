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

    // MARK: - Config

    private let port: NWEndpoint.Port
    private let preferences: BroadcastPreferences
    private var preferencesSubscription: AnyCancellable?
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
    #endif

    // MARK: - Internals

    /// Per-station encode/serve state. Non-Sendable because it's always
    /// accessed from the main actor; the detached tasks inside only hold
    /// weak refs to the broadcaster and reach back through `MainActor.run`.
    private final class BroadcastPipeline {
        let station: Station
        let buffer: AACRingBuffer
        /// Encoder bitrate this pipeline was started with. Frozen at
        /// construction — AACEncoder doesn't support live bitrate changes,
        /// so a live pipeline keeps its original setting until stopped.
        let bitrate: Int
        let sampleRate: Double
        /// Station name snapshot frozen at broadcast-start time. The ♥
        /// save flow needs a human-readable folder name per station
        /// without having to reach into the (separately-owned)
        /// StationManager.
        let stationName: String
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
            self.stationName = station.name
        }
    }

    private var pipelines: [Station.ID: BroadcastPipeline] = [:]
    private var listener: NWListener?
    /// Connected clients keyed by connection identity. We store the
    /// station each client is bound to so disconnects decrement the
    /// right listener count.
    private var clients: [ObjectIdentifier: (connection: NWConnection, stationID: Station.ID)] = [:]
    private var clientTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Construct a broadcaster bound to a specific port. Primarily for
    /// tests that need deterministic ports without trampling the
    /// user-facing preferences — production callers should prefer
    /// ``init(preferences:downloadService:nts:history:)``.
    public init(port: UInt16 = 18000) {
        // Force-unwrap: NWEndpoint.Port(rawValue:) only returns nil for 0.
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
        self.preferences = BroadcastPreferences.shared
        #if os(macOS)
        self.downloadService = nil
        self.nts = nil
        self.history = nil
        self.libraryConfig = nil
        self.tasteProfile = nil
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
        tasteProfile: TasteProfile? = nil
    ) {
        self.preferences = preferences
        let raw = UInt16(clamping: preferences.port)
        self.port = NWEndpoint.Port(rawValue: raw) ?? .any
        self.downloadService = downloadService
        self.nts = nts
        self.history = history
        self.libraryConfig = libraryConfig
        self.tasteProfile = tasteProfile
        subscribeToPreferences()
    }
    #else
    /// iOS flavour keeps the tighter surface area — no NTS / tunnel / venv
    /// wiring on that platform today.
    public init(preferences: BroadcastPreferences) {
        self.preferences = preferences
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
            let source = PlaylistSource(tracks: queue)
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

        let controller = NTSStationController(
            config: config,
            nts: nts,
            history: history,
            resolver: resolver
        )
        return NTSSource(controller: controller)
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

        let apiKey = preferences.lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
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

        let client = LastFMClient(apiKey: apiKey)
        // Fall back to a fresh empty TasteProfile when the broadcaster
        // wasn't wired up with one (test configs / legacy init). Scoring
        // against an empty profile just yields zero weights — the pool
        // still narrows via filters, it just loses the "you'd probably
        // like this" boost.
        let profile = tasteProfile ?? TasteProfile()
        let controller = LastFMStationController(
            config: config,
            client: client,
            history: history,
            resolver: resolver,
            tasteProfile: profile
        )
        return LastFMSource(controller: controller)
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
        broadcasting.insert(station.id)
        listenerCount[station.id] = 0

        let buffer = pipeline.buffer
        let stationID = station.id
        let stationName = station.name
        pipeline.encodeTask = Task.detached { [weak self, buffer] in
            await Self.runEncodeLoop(
                source: source,
                stationID: stationID,
                stationName: stationName,
                buffer: buffer,
                bitrate: bitrate,
                sampleRate: sampleRate,
                owner: self
            )
        }

        #if os(macOS)
        // First-station bootstrap for the tunnel. `CloudflareTunnel.start`
        // is idempotent, but gating on count avoids spurious log churn.
        if broadcasting.count == 1 {
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
        guard let pipeline = pipelines[stationID] else { return }

        pipeline.encodeTask?.cancel()
        pipelines.removeValue(forKey: stationID)
        broadcasting.remove(stationID)
        listenerCount.removeValue(forKey: stationID)
        currentItemByStation.removeValue(forKey: stationID)

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
    public func stopAll() {
        for id in Array(pipelines.keys) {
            stopBroadcast(stationID: id)
        }
        // A full stop resets the "needs restart" banner — the next start
        // will pick up current preferences as its fresh baseline.
        needsRestart = false
    }

    /// Whether `stationID` is currently broadcasting.
    public func isBroadcasting(stationID: Station.ID) -> Bool {
        broadcasting.contains(stationID)
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
        // to the next item. Buffered AAC already written for this track
        // still plays out; only future bytes come from the new track.
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

        listener?.cancel()
        listener = nil
    }

    /// Called from the detached encode loop each time the decoder opens a
    /// new track. Drives the ICY metadata surfaced to clients at the next
    /// block boundary.
    fileprivate func updateCurrentItem(_ item: TrackSourceItem?, stationID: Station.ID) {
        if let item {
            currentItemByStation[stationID] = item
        } else {
            currentItemByStation.removeValue(forKey: stationID)
        }
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
                    self.logger.error("listener failed: \(String(describing: err))")
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
        let likeHandler: @Sendable (UUID) async -> (Int, Data) = { [weak self] stationID in
            // Hop to the main actor to resolve the pipeline snapshot,
            // then do the copy + history mark off-main without pinning
            // the UI thread. `performLikeAsync` is the async bridge.
            await self?.performLikeAsync(stationID: stationID)
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

            // CORS preflight for /like — browsers send OPTIONS before the
            // real POST because we use Content-Type: application/json.
            if method == "OPTIONS" && path == "/like" {
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

                let (status, payload) = await likeHandler(stationID)
                var headers = Self.corsHeaders()
                headers["Content-Type"] = "application/json"
                _ = await Self.send(
                    data: Self.buildHTTPResponse(status: status, headers: headers, body: payload),
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

            // Legacy endpoint: redirect to the first broadcasting station
            // so existing bookmarks keep working. 404 when nothing's live.
            if path == "/stream.aac" || path == "/stream" {
                if let slug = await legacyRedirectSlug() {
                    _ = await Self.send(
                        data: Data(Self.redirectResponse(slug: slug, port: port).utf8),
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
    }

    private func removeClient(_ id: ObjectIdentifier) {
        if let entry = clients.removeValue(forKey: id) {
            if let count = listenerCount[entry.stationID], count > 0 {
                listenerCount[entry.stationID] = count - 1
            }
            logger.info(
                "client disconnected, remaining \(self.listenerCount[entry.stationID] ?? 0, privacy: .public)"
            )
        }
        clientTasks.removeValue(forKey: id)
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
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
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

    /// Any body bytes that came along in the same packet as the headers.
    /// `readUntilHeaderEnd` returns the header block including the
    /// terminating `\r\n\r\n`, but if the client bundled the body into the
    /// same read it's also sitting in the buffer — this peels that off.
    nonisolated static func bodyBytes(after headerBytes: Data) -> Data {
        // Technically the helper stops at the end of the header block, so
        // this is always empty. Kept for symmetry with `readBody` if we
        // ever switch to a more lenient reader.
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
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: min(needed, 4_096)
                ) { data, _, _, _ in
                    cont.resume(returning: data)
                }
            }
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

    nonisolated static func redirectResponse(slug: String, port: UInt16) -> String {
        let target = "http://localhost:\(port)/stream/\(slug).aac"
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

    /// JSON body accepted by `POST /like`. Kept internal to the broadcaster
    /// since no caller outside this file assembles one manually.
    struct LikeRequest: Decodable {
        let station: String
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

    /// Outcome of the main-actor preflight: either a ready-to-execute
    /// snapshot, or an early-exit HTTP status + JSON payload.
    private enum LikePreflight {
        case ready(LikeSnapshot)
        case early(Int, Data)
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
        guard let historyID = item.historyID else {
            return .early(409, Self.encodeLikeResponse(LikeResponse(
                status: "error", path: nil, message: "track already in library"
            )))
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
    /// 2. Bail 409 if the item has no `historyID` (playlist tracks are
    ///    already in the user's library, not in the transient cache).
    /// 3. File copy + `history.markSaved` off the main actor.
    func performLikeAsync(stationID: UUID) async -> (Int, Data) {
        let snapshot: LikeSnapshot
        switch likePreflight(stationID: stationID) {
        case .early(let status, let data):
            return (status, data)
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

    /// Public in-app entry point for the Mac UI's ♥ button. Thin async
    /// wrapper over ``performLikeAsync(stationID:)`` that hands back the
    /// decoded response so callers can render state directly.
    @discardableResult
    public func likeCurrent(stationID: Station.ID) async -> LikeResponse {
        let (_, data) = await performLikeAsync(stationID: stationID)
        if let decoded = try? JSONDecoder().decode(LikeResponse.self, from: data) {
            return decoded
        }
        return LikeResponse(status: "error", path: nil, message: "decode failed")
    }

    /// Copy the cached file into `~/<musicFolder>/Saved from <station>/<artist> — <title>.m4a`.
    /// Idempotent: if the destination already exists we return its path
    /// rather than throwing. This keeps the UI behaviour for double-clicks
    /// ("yes, still saved") consistent without extra round-trips.
    nonisolated private static func saveCached(
        cachedURL: URL,
        artist: String,
        title: String,
        stationName: String,
        musicFolder: URL
    ) throws -> String {
        let folder = musicFolder.appendingPathComponent(
            "Saved from \(sanitize(stationName))",
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
    func performLikeAsync(stationID: UUID) async -> (Int, Data) {
        let payload = Data("{\"message\":\"unavailable\",\"path\":null,\"status\":\"error\"}".utf8)
        return (500, payload)
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
    private func buildNowPayload() -> Data {
        struct NowStation: Encodable {
            let id: String
            let name: String
            let slug: String
            let broadcasting: Bool
            let streamURL: String?
            let listeners: Int
            let currentTrack: NowTrack?
        }
        struct NowTrack: Encodable {
            let title: String
            let artist: String
            let album: String
        }
        struct NowResponse: Encodable {
            let stations: [NowStation]
        }

        // Stable ordering by station name so UI doesn't jitter between
        // polls. Dictionary iteration isn't deterministic in Swift.
        let ordered = pipelines.values.sorted { $0.station.name < $1.station.name }
        let stations: [NowStation] = ordered.map { pipeline in
            let item = currentItemByStation[pipeline.station.id]
            let listeners = listenerCount[pipeline.station.id] ?? 0
            // `NowTrack.album` kept for UI backwards compat, but TrackSource
            // items don't carry album metadata — empty string is fine.
            return NowStation(
                id: pipeline.station.id.uuidString,
                name: pipeline.station.name,
                slug: pipeline.station.slug,
                broadcasting: true,
                streamURL: "/stream/\(pipeline.station.slug).aac",
                listeners: listeners,
                currentTrack: item.map {
                    NowTrack(
                        title: $0.title ?? "",
                        artist: $0.artist ?? "",
                        album: ""
                    )
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
            if let range = acc.range(of: Data("\r\n\r\n".utf8)) {
                return acc[..<range.upperBound]
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

            let nextItem: TrackSourceItem?
            do {
                nextItem = try await source.nextURL()
            } catch {
                log.error("source error: \(String(describing: error), privacy: .public)")
                break
            }

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
                log.error("open failed for \(label, privacy: .public): \(String(describing: error))")
                continue outer
            }

            while !Task.isCancelled {
                // User-initiated skip? Break the inner loop so the outer
                // loop pulls the next item. Already-encoded bytes in the
                // ring buffer play out for any current listener — the
                // skip kicks in at the track boundary from their POV.
                if let owner {
                    let skip = await MainActor.run { owner.consumeSkipRequest(stationID: stationID) }
                    if skip { break }
                }
                guard let pcm = decoder.readNextBuffer() else {
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
        }

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
                    owner.stopBroadcast(stationID: stationID)
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
