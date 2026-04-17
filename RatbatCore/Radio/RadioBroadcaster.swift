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
    /// Per-station currently-encoding track. Drives ICY `StreamTitle`
    /// updates and the "Now: Artist — Title" UI snippet.
    @Published public private(set) var currentTrackByStation: [Station.ID: Track] = [:]
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
        var encodeTask: Task<Void, Never>?

        init(station: Station, buffer: AACRingBuffer, bitrate: Int, sampleRate: Double) {
            self.station = station
            self.buffer = buffer
            self.bitrate = bitrate
            self.sampleRate = sampleRate
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
    /// ``init(preferences:)``.
    public init(port: UInt16 = 18000) {
        // Force-unwrap: NWEndpoint.Port(rawValue:) only returns nil for 0.
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
        self.preferences = BroadcastPreferences.shared
        subscribeToPreferences()
    }

    /// Construct a broadcaster backed by a user preferences store. The
    /// broadcaster snapshots `prefs.port` at init time — live port changes
    /// require stopAll + re-init (flagged via ``needsRestart``). Quality
    /// and sample-rate changes also flag a restart but can be picked up on
    /// the next startBroadcast without recreating the broadcaster.
    public init(preferences: BroadcastPreferences) {
        self.preferences = preferences
        let raw = UInt16(clamping: preferences.port)
        self.port = NWEndpoint.Port(rawValue: raw) ?? .any
        subscribeToPreferences()
    }

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

    /// Start broadcasting `station`. Spins up its encode loop and (if not
    /// already running) the shared HTTP listener + Cloudflare tunnel.
    /// No-op if the station is already live or its queue is empty.
    public func startBroadcast(station: Station) async {
        guard !broadcasting.contains(station.id) else { return }
        guard !station.queue.isEmpty else {
            error = "Cannot broadcast an empty queue"
            return
        }
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
        pipeline.encodeTask = Task.detached { [weak self, buffer] in
            await Self.runEncodeLoop(
                queue: station.queue,
                stationID: station.id,
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
        currentTrackByStation.removeValue(forKey: stationID)

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
    fileprivate func updateCurrentTrack(_ track: Track?, stationID: Station.ID) {
        if let track {
            currentTrackByStation[stationID] = track
        } else {
            currentTrackByStation.removeValue(forKey: stationID)
        }
    }

    /// Snapshot of the current track for a detached serve loop. Lets a
    /// client task ask "what's playing for MY station?" without grabbing
    /// the whole actor state.
    fileprivate func snapshotCurrentTrack(stationID: Station.ID) -> Track? {
        currentTrackByStation[stationID]
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

        let task = Task.detached { [weak self] in
            // Read headers to learn both the request path and whether the
            // client wants ICY metadata — two pieces of information from
            // the same read.
            let headerBytes = await Self.readUntilHeaderEnd(connection: connection)
            let path = Self.requestPath(from: headerBytes) ?? "/stream.aac"
            let wantsMetadata = Self.headerRequestsICYMetadata(headerBytes)

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
        case 302: statusText = "Found"
        case 404: statusText = "Not Found"
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
            let track = currentTrackByStation[pipeline.station.id]
            let listeners = listenerCount[pipeline.station.id] ?? 0
            return NowStation(
                id: pipeline.station.id.uuidString,
                name: pipeline.station.name,
                slug: pipeline.station.slug,
                broadcasting: true,
                streamURL: "/stream/\(pipeline.station.slug).aac",
                listeners: listeners,
                currentTrack: track.map {
                    NowTrack(title: $0.title, artist: $0.artist, album: $0.album)
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
        var lastAnnouncedTrackID: UUID?

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

                    let track = await MainActor.run {
                        ownerRef()?.snapshotCurrentTrack(stationID: stationID)
                    }
                    let trackChanged = track?.id != lastAnnouncedTrackID
                    let meta = ICYMetadata.block(for: track, trackChanged: trackChanged)
                    let ok = await send(data: meta, on: connection)
                    if !ok { return }
                    if trackChanged { lastAnnouncedTrackID = track?.id }

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
        queue: [Track],
        stationID: Station.ID,
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

        var trackIndex = 0
        while !Task.isCancelled {
            let track = queue[trackIndex % queue.count]
            do {
                try decoder.open(track)
                log.info("decoding \(track.title, privacy: .public)")
                if let owner {
                    await MainActor.run { owner.updateCurrentTrack(track, stationID: stationID) }
                }
            } catch {
                log.error("open failed for \(track.title, privacy: .public): \(String(describing: error))")
                trackIndex += 1
                continue
            }

            while !Task.isCancelled {
                guard let pcm = decoder.readNextBuffer() else {
                    break   // EOF — advance queue
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
            trackIndex += 1
        }

        decoder.close()
        if let owner {
            await MainActor.run { owner.updateCurrentTrack(nil, stationID: stationID) }
        }
        log.info("encode loop exiting")
    }
}
