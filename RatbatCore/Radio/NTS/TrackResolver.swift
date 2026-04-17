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

    private let venvPython: URL
    private let wrapperScript: URL
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "resolver")

    public init(
        venvPython: URL,
        wrapperScript: URL,
        cacheRoot: URL? = nil
    ) throws {
        self.venvPython = venvPython
        self.wrapperScript = wrapperScript

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

        let proc = Process()
        proc.executableURL = venvPython
        proc.arguments = [
            wrapperScript.path,
            "--artist", artist,
            "--title", title,
            "--output", outURL.path,
        ]

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
            if exit == 1 || errMsg.contains("NO_MATCH") {
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
