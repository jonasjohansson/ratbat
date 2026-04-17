import Foundation
import AVFoundation
import AudioToolbox
import Network
import OSLog

/// End-to-end HTTP AAC broadcaster for a station's track queue.
///
/// Spike (Task 3.2): proves the pipeline
/// `[Track] → AVAudioFile → PCM → AAC/ADTS → NWListener → HTTP client`
/// can hang together before we productionise any piece of it. Explicitly
/// independent of ``AudioPlayer`` — the broadcaster opens its own handle
/// on the same file AudioPlayer might be playing, decodes in parallel,
/// and streams. That keeps AVPlayer untouched and means the station can
/// broadcast while the user listens to something else on the local
/// speaker bus.
///
/// Runs on the main actor so published UI state (`isBroadcasting`,
/// `listenerCount`, `currentURL`) is safe for SwiftUI to observe directly.
/// The broadcast task itself offloads CPU work (file read + encode) to
/// a detached task and posts progress back via `Task { @MainActor }`.
///
/// macOS-only because `Network.framework` listeners aren't something
/// we've tested on iOS (and the iOS app doesn't have a broadcast flow
/// wired up anyway — that's a later phase).
@MainActor
public final class RadioBroadcaster: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var isBroadcasting = false
    @Published public private(set) var listenerCount = 0
    /// URL a client should point VLC / a browser at. `nil` when idle.
    @Published public private(set) var currentURL: URL?
    #if os(macOS)
    /// Public tunnel that exposes the LAN-only `currentURL` out to the
    /// internet via cloudflared. Owned by the broadcaster so its lifecycle
    /// matches `start`/`stop` — the UI just observes `tunnel.publicURL`.
    /// macOS-only because `Process.run()` is unavailable on iOS; iOS
    /// doesn't have a broadcast flow wired up anyway.
    public let tunnel: CloudflareTunnel = CloudflareTunnel()
    #endif
    /// Last error surfaced by the listener or the decode/encode loop.
    /// String-typed so the UI can just render it; callers who want
    /// structured errors should read OSLog.
    @Published public private(set) var error: String?
    /// Track the encode loop is currently feeding into the stream, or
    /// `nil` when idle / between tracks. Published so UI can show
    /// "Broadcasting: Artist — Title" without poking the encoder.
    @Published public private(set) var currentlyBroadcastingTrack: Track?

    // MARK: - Config

    private let port: NWEndpoint.Port
    /// Hardcoded for v1 — later we can derive this from the `Station` the
    /// broadcaster is attached to so each station gets its own label.
    private let stationName: String = "Johanssound"
    private let logger = Logger(
        subsystem: "se.jonasjohansson.johanssound",
        category: "broadcaster"
    )

    // MARK: - Internals

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var clientTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var broadcastTask: Task<Void, Never>?
    /// Shared ring buffer between the encode loop (writer) and every
    /// client task (reader). Outlives a single broadcast so clients can
    /// hold references without a circular ownership hassle.
    private var ringBuffer: AACRingBuffer?

    public init(port: UInt16 = 18000) {
        // Force-unwrap: NWEndpoint.Port(rawValue:) only returns nil for 0.
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
    }

    // MARK: - Public API

    /// Start broadcasting ``queue``. v1 plays the queue sequentially and
    /// loops back to the start when it runs out. No-op if already
    /// broadcasting or if the queue is empty.
    public func start(queue: [Track]) async {
        guard !isBroadcasting else { return }
        guard !queue.isEmpty else {
            error = "Cannot broadcast an empty queue"
            return
        }
        error = nil

        let buffer = AACRingBuffer()
        ringBuffer = buffer

        do {
            try startHTTPServer(buffer: buffer)
        } catch {
            self.error = "Listener failed to start: \(error.localizedDescription)"
            logger.error("listener start failed: \(String(describing: error))")
            ringBuffer = nil
            return
        }

        isBroadcasting = true
        currentURL = URL(string: "http://localhost:\(port.rawValue)/stream.aac")

        broadcastTask = Task.detached { [weak self, buffer] in
            await Self.runEncodeLoop(queue: queue, buffer: buffer, owner: self)
        }

        #if os(macOS)
        // Kick off the public tunnel in parallel. Don't await it here —
        // the broadcast is already live on localhost, and the tunnel URL
        // appearing is a nice-to-have that can take a few seconds.
        let tunnelPort = port.rawValue
        Task { [weak self] in
            await self?.tunnel.start(forwardingTo: tunnelPort)
        }
        #endif

        logger.info("broadcast started on port \(self.port.rawValue, privacy: .public)")
    }

    /// Stop the broadcast. Tears down the listener, closes clients,
    /// cancels the encode task, and clears published state. Idempotent.
    public func stop() {
        guard isBroadcasting || listener != nil else { return }

        #if os(macOS)
        // Tear the public tunnel down first so listeners get a clean
        // connection close rather than a dangling proxy to a dead port.
        tunnel.stop()
        #endif

        broadcastTask?.cancel()
        broadcastTask = nil

        for (_, task) in clientTasks {
            task.cancel()
        }
        clientTasks.removeAll()

        for (_, conn) in clients {
            conn.cancel()
        }
        clients.removeAll()

        listener?.cancel()
        listener = nil
        ringBuffer = nil

        isBroadcasting = false
        listenerCount = 0
        currentURL = nil
        currentlyBroadcastingTrack = nil

        logger.info("broadcast stopped")
    }

    /// Called from the detached encode loop (via `MainActor.run`) each time
    /// the decoder opens a new track. Drives the ICY metadata we publish
    /// to connected clients on their next metadata block boundary.
    fileprivate func updateCurrentTrack(_ track: Track?) {
        currentlyBroadcastingTrack = track
    }

    /// Snapshot of the current track for detached serve loops. Lets a
    /// client task ask "what's playing right now?" without needing an
    /// unsafe reference back to the broadcaster.
    fileprivate func snapshotCurrentTrack() -> Track? {
        currentlyBroadcastingTrack
    }

    // MARK: - HTTP server

    private func startHTTPServer(buffer: AACRingBuffer) throws {
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
                    self.stop()
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
                self.handleClient(connection, buffer: buffer)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func handleClient(_ connection: NWConnection, buffer: AACRingBuffer) {
        let id = ObjectIdentifier(connection)
        clients[id] = connection
        listenerCount = clients.count
        logger.info("client connected, total \(self.listenerCount, privacy: .public)")

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

        connection.start(queue: .global(qos: .userInitiated))

        let stationName = self.stationName
        let task = Task.detached { [weak self] in
            await Self.serveClient(
                connection: connection,
                buffer: buffer,
                stationName: stationName,
                ownerRef: { [weak self] in self }
            )
            // When serving exits (client gone, task cancelled), make sure
            // the connection is torn down and we drop our reference.
            connection.cancel()
            await MainActor.run { [weak self] in
                self?.removeClient(id)
            }
        }
        clientTasks[id] = task
    }

    private func removeClient(_ id: ObjectIdentifier) {
        if clients.removeValue(forKey: id) != nil {
            listenerCount = clients.count
            logger.info("client disconnected, remaining \(self.listenerCount, privacy: .public)")
        }
        clientTasks.removeValue(forKey: id)
    }

    // MARK: - Client serving (detached)

    /// Reads the HTTP request line(s), sends a minimal 200 response,
    /// then pumps ring-buffer data until the connection goes away. If
    /// the client requested ICY metadata (`Icy-MetaData: 1`), we
    /// interleave a metadata block after every `blockInterval` audio
    /// bytes written to THIS client — byte counters are per-client
    /// because different clients connect at different moments.
    private static func serveClient(
        connection: NWConnection,
        buffer: AACRingBuffer,
        stationName: String,
        ownerRef: @escaping @Sendable () -> RadioBroadcaster?
    ) async {
        // Read + parse the HTTP request headers so we know whether the
        // client opted in to ICY metadata.
        let headerBytes = await readUntilHeaderEnd(connection: connection)
        let wantsMetadata = headerRequestsICYMetadata(headerBytes)

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
                // Either cancelled or a spurious wake-up. Yield and
                // re-check — the read(from:) contract says we'll get
                // real data next time if more has been written.
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
                    // Fill the current interval, emit a meta block,
                    // then carry the leftover forward.
                    let fill = remaining.prefix(room)
                    if !fill.isEmpty {
                        let ok = await send(data: Data(fill), on: connection)
                        if !ok { return }
                    }
                    remaining = remaining.dropFirst(room)

                    let track = await MainActor.run { ownerRef()?.snapshotCurrentTrack() }
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
    private static func headerRequestsICYMetadata(_ bytes: Data) -> Bool {
        guard let text = String(data: bytes, encoding: .utf8) else { return false }
        // Normalise to `\n` then split — splitting on a Character set of
        // `\r` and `\n` is tempting but Swift's split-on-closure has bitten
        // us before, so we do it the dull explicit way.
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
    /// advertise `icy-metaint`, a station name, and a genre — VLC shows
    /// `icy-name` in its "Current Media" panel as the station label.
    private static func buildResponseHeader(
        wantsMetadata: Bool,
        stationName: String
    ) -> String {
        if wantsMetadata {
            return """
            HTTP/1.1 200 OK\r
            Content-Type: audio/aac\r
            icy-metaint: \(ICYMetadata.blockInterval)\r
            icy-name: \(stationName)\r
            icy-genre: Johanssound Radio\r
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

    private static func readUntilHeaderEnd(
        connection: NWConnection,
        cap: Int = 4096
    ) async -> Data {
        var acc = Data()
        while acc.count < cap {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 512
                ) { data, _, isComplete, error in
                    if error != nil || isComplete {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(returning: data)
                    }
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

    private static func send(data: Data, on connection: NWConnection) async -> Bool {
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
        buffer: AACRingBuffer,
        owner: RadioBroadcaster?
    ) async {
        let decoder = AudioDecoder()
        let log = Logger(
            subsystem: "se.jonasjohansson.johanssound",
            category: "broadcaster.encode"
        )

        let encoder: AACEncoder
        do {
            encoder = try AACEncoder(inputFormat: AudioDecoder.outputFormat)
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
                // Publish the track so per-client serve loops pick it up
                // in their next ICY metadata block.
                if let owner {
                    await MainActor.run { owner.updateCurrentTrack(track) }
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
            await MainActor.run { owner.updateCurrentTrack(nil) }
        }
        log.info("encode loop exiting")
    }
}
