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

        public init(cachedURL: URL, youtubeID: String, matchedTitle: String, fileSize: Int64) {
            self.cachedURL = cachedURL
            self.youtubeID = youtubeID
            self.matchedTitle = matchedTitle
            self.fileSize = fileSize
        }
    }

    public enum Error: Swift.Error, Sendable, Equatable {
        case venvNotReady
        case resolverScriptMissing
        case noYouTubeMatch(artist: String, title: String)
        case downloadFailed(String)
        case notConfigured(String)      // prefs / paths etc.
    }

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

    private let venvPython: URL
    private let wrapperScript: URL
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "resolver")

    public init(
        venvPython: URL,
        wrapperScript: URL,
        cacheRoot: URL? = nil,
        cacheCapBytes: Int64 = 10 * 1024 * 1024 * 1024
    ) throws {
        self.venvPython = venvPython
        self.wrapperScript = wrapperScript
        self.cacheCapBytes = cacheCapBytes

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

        let proc = Process()
        proc.executableURL = venvPython
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw Error.downloadFailed("failed to spawn resolver: \(error.localizedDescription)")
        }

        // Drain both pipes concurrently; waitUntilExit() alone can deadlock
        // if the child fills a pipe buffer before we read it.
        async let stdoutData = readAll(pipe: outPipe)
        async let stderrData = readAll(pipe: errPipe)
        let (outData, errData) = await (stdoutData, stderrData)
        proc.waitUntilExit()

        let exit = proc.terminationStatus
        let errMsg = String(data: errData, encoding: .utf8)?
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

        struct WrapperOutput: Decodable {
            let youtube_id: String
            let matched_title: String
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
            fileSize: size
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

    // MARK: - Private

    private nonisolated func readAll(pipe: Pipe) async -> Data {
        await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            // readDataToEndOfFile is blocking; hop off the actor/caller thread.
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: data)
            }
        }
    }
}
#endif
