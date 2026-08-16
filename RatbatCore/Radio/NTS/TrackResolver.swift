#if os(macOS)
import Foundation
import OSLog

/// Resolves an (artist, title) pair to a locally-cached audio file.
///
/// Station lifecycle calls this with each NTS tracklist entry — we search
/// YouTube Music via `ytmusicapi`, download the best match with `yt-dlp`,
/// and return a file URL in `~/Library/Caches/Ratbat/station-cache/` plus
/// the matched YouTube ID for dedup.
///
/// This actor does *not* bootstrap the Python venv — it assumes
/// ``DownloadService/ensureReady()`` has already run and takes the
/// resolved `venvPython` + wrapper script paths in its initializer.
///
/// The cache is transient: files here are not the user's music library
/// and are safe to nuke at any time. Primitives for size-aware pruning
/// are exposed (``cacheSize()``, ``cachedFilesOldestFirst()``,
/// ``prune(at:)``) but the actual LRU policy lives with the caller.
public actor TrackResolver {

    public struct Resolution: Sendable, Hashable {
        public let cachedURL: URL        // local file path on disk
        public let youtubeID: String     // e.g. "dQw4w9WgXcQ"
        public let matchedTitle: String  // what YouTube actually called it
        public let fileSize: Int64       // bytes

        /// Display metadata the extractor already knew. All optional: which
        /// of these an extractor fills varies (Bandcamp reliably has album
        /// art and duration; a YouTube Music single often has no album at
        /// all), and the wrapper only emits keys it actually found. The
        /// downloaded file is never mutated to carry them — see
        /// `_describe` in `resolve_track.py` for why.
        public let album: String?
        public let duration: TimeInterval?
        /// Remote cover-art URL on the source's own CDN.
        public let artworkURL: String?

        public init(
            cachedURL: URL,
            youtubeID: String,
            matchedTitle: String,
            fileSize: Int64,
            album: String? = nil,
            duration: TimeInterval? = nil,
            artworkURL: String? = nil
        ) {
            self.cachedURL = cachedURL
            self.youtubeID = youtubeID
            self.matchedTitle = matchedTitle
            self.fileSize = fileSize
            self.album = album
            self.duration = duration
            self.artworkURL = artworkURL
        }
    }

    public enum Error: Swift.Error, Sendable, Equatable {
        case venvNotReady
        case resolverScriptMissing
        case noYouTubeMatch(artist: String, title: String)
        case downloadFailed(String)
        case notConfigured(String)      // prefs / paths etc.
        case timedOut(seconds: Int)
    }

    // MARK: - The subprocess boundary

    /// One invocation of the external resolver.
    public struct Invocation: Sendable {
        public let executable: URL
        public let arguments: [String]

        public init(executable: URL, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }

        /// Value of `--output`, i.e. where the resolver was told to put the
        /// audio file. Handy for test doubles, which have to honour that
        /// contract for the caller's "file actually landed" check to pass.
        public var outputPath: String? {
            guard let i = arguments.firstIndex(of: "--output"),
                  arguments.index(after: i) < arguments.endIndex
            else { return nil }
            return arguments[arguments.index(after: i)]
        }
    }

    /// What the external resolver reported back.
    public struct Output: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let exitCode: Int32

        public init(stdout: Data, stderr: Data, exitCode: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    /// How the resolver reaches the outside world.
    ///
    /// Injectable so tests can exercise argument construction, exit-code
    /// handling and JSON parsing without spawning anything — the logic in
    /// ``runResolver(artist:title:sourceURL:)`` is the part worth testing,
    /// and a real subprocess only adds a dependency on the host having a
    /// shell, a writable temp dir and a scheduler that cooperates.
    ///
    /// Implementations must respect `timeout` and throw ``Error/timedOut(seconds:)``
    /// rather than blocking indefinitely.
    public typealias Runner = @Sendable (Invocation, Duration) async throws -> Output

    /// Base cache dir. Transient — safe to nuke anytime.
    public let cacheRoot: URL

    /// Soft ceiling on the on-disk cache. After each resolve we trim the
    /// oldest files back under this. An always-on station downloads a new
    /// track every few minutes (~50 MB/hr at 128 kbps) and nothing else
    /// reclaims the space, so without this the cache grows until the disk
    /// fills and writes start failing. 10 GB ≈ a couple hundred tracks of
    /// runway, which is plenty given we only ever replay from history, not
    /// from this transient cache.
    public let cacheCapBytes: Int64

    /// Hard ceiling on a single resolve. A search-and-download of one track
    /// is normally seconds; anything past this is yt-dlp wedged on a stalled
    /// socket or a host that never answers. Station controllers `await` this
    /// call inside their next-track loop, so an unbounded resolve is not a
    /// slow resolve — it is a station that never plays another track and
    /// never says why.
    public let timeout: Duration

    private let venvPython: URL
    private let wrapperScript: URL
    private let runner: Runner
    private let logger = Logger(subsystem: RatbatLog.subsystem, category: "resolver")

    public init(
        venvPython: URL,
        wrapperScript: URL,
        cacheRoot: URL? = nil,
        cacheCapBytes: Int64 = 10 * 1024 * 1024 * 1024,
        timeout: Duration = .seconds(300),
        runner: @escaping Runner = TrackResolver.spawnSubprocess
    ) throws {
        self.venvPython = venvPython
        self.wrapperScript = wrapperScript
        self.cacheCapBytes = cacheCapBytes
        self.timeout = timeout
        self.runner = runner

        let root: URL
        if let cacheRoot {
            root = cacheRoot
        } else {
            root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ratbat/station-cache", isDirectory: true)
        }
        self.cacheRoot = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Resolve

    /// Returns a ``Resolution`` for the best YouTube Music match.
    ///
    /// - Throws: ``Error/noYouTubeMatch(artist:title:)`` if nothing found,
    ///   ``Error/downloadFailed(_:)`` for any subprocess / parsing problem,
    ///   ``Error/venvNotReady`` if the configured Python binary doesn't exist,
    ///   ``Error/resolverScriptMissing`` if the wrapper script is missing.
    public func resolve(artist: String, title: String) async throws -> Resolution {
        try await runResolver(artist: artist, title: title, sourceURL: nil)
    }

    /// Dispatches to the direct-URL shortcut when the candidate carries a
    /// pre-resolved audio URL, otherwise falls back to the standard
    /// YouTube-Music search path.
    ///
    /// Sources that already know where the audio lives (Bandcamp's discover
    /// endpoint hands us the release page URL in stage 1) set
    /// ``SourceCandidate/resolvedURL``. When that's present we skip the
    /// `ytmusicapi` search and let yt-dlp's extractor (e.g. `BandcampIE`)
    /// handle the URL directly — no second-round matching that could pick
    /// a different artist's cover, and no wasted API calls.
    ///
    /// The resulting ``Resolution/youtubeID`` is a synthetic identifier of
    /// the form `"<extractor>:<id>"` (e.g. `"bandcamp:1234567890"`) so
    /// downstream code can still use it as an opaque dedup key.
    ///
    /// - Throws: same set as ``resolve(artist:title:)``, plus
    ///   ``Error/downloadFailed(_:)`` for a direct-URL fetch that fails
    ///   (there is no ``Error/noYouTubeMatch(artist:title:)`` in this path
    ///   — the caller picked the URL, so "nothing found" isn't a concept).
    public func resolve(candidate: SourceCandidate) async throws -> Resolution {
        try await runResolver(
            artist: candidate.artist,
            title: candidate.title,
            sourceURL: candidate.resolvedURL
        )
    }

    /// Shared subprocess invocation for both the search-and-download path
    /// and the direct-URL path. When `sourceURL` is non-nil the wrapper
    /// skips its YT-Music search stage and hands the URL to yt-dlp as-is.
    private func runResolver(
        artist: String,
        title: String,
        sourceURL: URL?
    ) async throws -> Resolution {
        // Sanity-check paths up-front so the failure mode is obvious.
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else {
            throw Error.venvNotReady
        }
        guard FileManager.default.fileExists(atPath: wrapperScript.path) else {
            throw Error.resolverScriptMissing
        }

        // Stable filename — UUID prefix keeps cache cleanup simple and
        // avoids leaking artist/title characters into the filesystem.
        let outFilename = "\(UUID().uuidString).m4a"
        let outURL = cacheRoot.appendingPathComponent(outFilename)

        var arguments: [String] = [
            wrapperScript.path,
            "--artist", artist,
            "--title", title,
            "--output", outURL.path,
        ]
        if let sourceURL {
            arguments.append(contentsOf: ["--source-url", sourceURL.absoluteString])
        }

        let invocation = Invocation(executable: venvPython, arguments: arguments)
        let output: Output
        do {
            output = try await runner(invocation, timeout)
        } catch let error as Error {
            // Timeouts and spawn failures both land here. The partial file,
            // if any, is ours to clean up — nobody downstream knows about it.
            try? FileManager.default.removeItem(at: outURL)
            logger.error("resolve failed for \(artist, privacy: .public) — \(title, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw Error.downloadFailed("resolver invocation failed: \(error.localizedDescription)")
        }

        let outData = output.stdout
        let exit = output.exitCode
        let errMsg = String(data: output.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard exit == 0 else {
            logger.error("resolve failed for \(artist, privacy: .public) — \(title, privacy: .public) [exit \(exit)]: \(errMsg, privacy: .public)")
            // Wrapper exits 1 on NO_MATCH and prints "NO_MATCH" to stderr.
            // NO_MATCH is only reachable on the search path — the direct-URL
            // path never runs the YT-Music search, so exit 1 there would be
            // a bug. Treat it as a generic download failure regardless.
            if sourceURL == nil && (exit == 1 || errMsg.contains("NO_MATCH")) {
                // Best effort: the wrapper shouldn't have produced a file,
                // but if an earlier partial write happened, clean it up.
                try? FileManager.default.removeItem(at: outURL)
                throw Error.noYouTubeMatch(artist: artist, title: title)
            }
            let detail = errMsg.isEmpty ? "exit code \(exit)" : errMsg
            try? FileManager.default.removeItem(at: outURL)
            throw Error.downloadFailed(detail)
        }

        // The display fields are optional so an older wrapper script —
        // one deployed before this contract grew — still decodes. A
        // resolver that can't parse its own stdout throws away a track
        // that already downloaded fine, so the contract only ever widens.
        struct WrapperOutput: Decodable {
            let youtube_id: String
            let matched_title: String
            let album: String?
            let duration: Double?
            let thumbnail: String?
        }
        let parsed: WrapperOutput
        do {
            parsed = try JSONDecoder().decode(WrapperOutput.self, from: outData)
        } catch {
            let raw = String(data: outData, encoding: .utf8) ?? "<non-utf8>"
            try? FileManager.default.removeItem(at: outURL)
            throw Error.downloadFailed("bad resolver stdout: \(raw)")
        }

        // Verify file actually landed where we asked.
        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw Error.downloadFailed("resolver reported success but no file at \(outURL.path)")
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int64) ?? 0
        logger.info("resolved \(artist, privacy: .public) — \(title, privacy: .public) → \(parsed.youtube_id, privacy: .public) (\(size) bytes)")

        // Trim the cache back under its cap now that we've added a file.
        // Best-effort: a pruning hiccup must never fail an otherwise-good
        // resolve, and we never evict the file we just wrote.
        enforceCacheCap(keeping: outURL)

        return Resolution(
            cachedURL: outURL,
            youtubeID: parsed.youtube_id,
            matchedTitle: parsed.matched_title,
            fileSize: size,
            album: parsed.album,
            duration: parsed.duration,
            artworkURL: parsed.thumbnail
        )
    }

    // MARK: - Cache primitives

    /// Delete a previously-resolved file. For cache pruning.
    public func prune(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Total bytes under `cacheRoot`. For cache-cap enforcement.
    public func cacheSize() throws -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let rv = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard rv.isRegularFile == true else { continue }
            total += Int64(rv.fileSize ?? 0)
        }
        return total
    }

    /// All cache files, oldest first (by modification time). For LRU eviction.
    public func cachedFilesOldestFirst() throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var entries: [(URL, Date)] = []
        for case let url as URL in enumerator {
            let rv = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard rv.isRegularFile == true else { continue }
            entries.append((url, rv.contentModificationDate ?? .distantPast))
        }
        entries.sort { $0.1 < $1.1 }
        return entries.map { $0.0 }
    }

    /// Evict oldest files until the cache is back under `cacheCapBytes`.
    /// Best-effort and non-throwing: any enumeration/delete error is logged
    /// and swallowed so it can't break a resolve. `keeping` (the file we
    /// just wrote) is never evicted, even though oldest-first ordering
    /// already protects it — belt and suspenders for tiny-cap configs.
    private func enforceCacheCap(keeping: URL) {
        do {
            var total = try cacheSize()
            guard total > cacheCapBytes else { return }

            let fm = FileManager.default
            let keepPath = keeping.standardizedFileURL.path
            var evicted = 0
            var freed: Int64 = 0
            for url in try cachedFilesOldestFirst() {
                // Stop once we're comfortably under the cap (10% headroom)
                // so we don't evict one file per resolve at the boundary.
                if total <= cacheCapBytes - cacheCapBytes / 10 { break }
                if url.standardizedFileURL.path == keepPath { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                do {
                    try fm.removeItem(at: url)
                    total -= Int64(size)
                    freed += Int64(size)
                    evicted += 1
                } catch {
                    logger.error("cache evict failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            if evicted > 0 {
                logger.info("cache trim: evicted \(evicted) file(s), freed \(freed) bytes, now \(total)/\(self.cacheCapBytes)")
            }
        } catch {
            logger.error("cache trim failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - The real runner

    /// Spawns the wrapper under the venv Python and captures its output,
    /// bounded by `timeout`.
    ///
    /// Two things here are deliberate, and both replace code that hung:
    ///
    /// 1. **No `Process.waitUntilExit()`.** That call services the *calling
    ///    thread's* run loop while it waits. Under Swift concurrency the
    ///    thread that resumes after an `await` is not necessarily the one
    ///    that called `run()`, so `waitUntilExit()` could end up spinning a
    ///    run loop that will never be told the child died — a permanent
    ///    hang, roughly one invocation in thirty on a busy machine. It also
    ///    blocks a cooperative-pool thread, which is never allowed. We wait
    ///    on `terminationHandler` instead, which is delivered by libdispatch
    ///    and has no thread affinity.
    ///
    /// 2. **Files, not pipes, for stdout/stderr.** A pipe wedges the child
    ///    once ~64 KB is unread, so pipes oblige you to run a concurrent
    ///    reader per stream and to get that right; a file never blocks the
    ///    writer and can be read once the child is gone. yt-dlp is chatty on
    ///    stderr, so this is not hypothetical.
    public static let spawnSubprocess: Runner = { invocation, timeout in
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratbat-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let proc = Process()
        proc.executableURL = invocation.executable
        proc.arguments = invocation.arguments
        proc.standardOutput = stdoutHandle
        proc.standardError = stderrHandle
        // Never let the resolver inherit a terminal and block on a prompt.
        proc.standardInput = FileHandle.nullDevice

        // Wire the termination handler *before* run(): a fast-exiting child
        // can be gone before the next line executes, and ProcessWatch is
        // built to absorb that ordering.
        let watch = ProcessWatch()
        proc.terminationHandler = { finished in watch.complete(finished.terminationStatus) }

        do {
            try proc.run()
        } catch {
            throw Error.downloadFailed("failed to spawn resolver: \(error.localizedDescription)")
        }

        // SIGTERM first so yt-dlp gets to clean up its `.part` files, then
        // SIGKILL for a child that ignores it. Signalling by pid rather than
        // holding onto `proc`, which is not Sendable and so can't cross into
        // the watchdog task.
        let pid = proc.processIdentifier
        let watchdog = Task { [watch] in
            try await Task.sleep(for: timeout)
            guard !watch.hasExited else { return }
            watch.markTimedOut()
            kill(pid, SIGTERM)
            try await Task.sleep(for: .seconds(5))
            if !watch.hasExited { kill(pid, SIGKILL) }
        }

        let exitCode = await watch.exitStatus()
        watchdog.cancel()

        // Close our write ends before reading so nothing is still in flight.
        try? stdoutHandle.close()
        try? stderrHandle.close()

        if watch.timedOut {
            throw Error.timedOut(seconds: Int(timeout.components.seconds))
        }

        return Output(
            stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
            stderr: (try? Data(contentsOf: stderrURL)) ?? Data(),
            exitCode: exitCode
        )
    }
}

/// One-shot bridge from `Process.terminationHandler` — a callback that may
/// fire on any queue, possibly before anyone is awaiting it — into a single
/// `await`, plus the watchdog's verdict on whether we killed the child.
///
/// Hand-locked rather than an actor because `terminationHandler` is a
/// synchronous non-isolated callback and cannot `await` its way in.
private final class ProcessWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?
    private var killedByWatchdog = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return killedByWatchdog
    }

    var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status != nil
    }

    func markTimedOut() {
        lock.lock()
        killedByWatchdog = true
        lock.unlock()
    }

    /// Idempotent: a process can only exit once, but be defensive about it.
    func complete(_ value: Int32) {
        lock.lock()
        guard status == nil else {
            lock.unlock()
            return
        }
        status = value
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: value)
    }

    func exitStatus() async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if let status {
                lock.unlock()
                cont.resume(returning: status)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }
}
#endif
