#if os(macOS)
import Foundation
import OSLog

/// Runs the bundled Python spotify-downloader as a subprocess and surfaces
/// @Published state for a UI to observe.
///
/// Plumbing-only — no UI here. See Task 2b for the SwiftUI layer.
@MainActor
public final class DownloadService: ObservableObject {

    // MARK: - Types

    public enum SetupState: Sendable, Equatable {
        case unknown
        case checking
        case installing(String)     // progress message
        case ready
        case failed(String)
    }

    public struct Job: Identifiable, Sendable, Hashable {
        public enum Status: Sendable, Hashable {
            case pending
            case matching
            case downloading
            case done
            case failed(String)
        }
        public let id: UUID
        public var title: String      // best-available label
        public var status: Status

        public init(id: UUID = UUID(), title: String, status: Status) {
            self.id = id
            self.title = title
            self.status = status
        }
    }

    public struct Batch: Identifiable, Sendable {
        public let id: UUID
        public let url: URL
        public let destination: URL
        public var jobs: [Job]
        public var startedAt: Date
        public var finishedAt: Date?
        public var errorMessage: String?

        public var isActive: Bool { finishedAt == nil }
        public var completedCount: Int {
            jobs.filter { if case .done = $0.status { return true }; return false }.count
        }
    }

    // MARK: - Published state

    @Published public private(set) var batches: [Batch] = []
    @Published public private(set) var setupState: SetupState = .unknown

    // MARK: - Private state

    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "downloader")
    private var processes: [Batch.ID: Process] = [:]

    public init() {}

    // MARK: - Setup paths

    /// App-support venv path.
    private var venvRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ratbat/downloader-venv")
    }

    /// Path to venv's Python interpreter (exists once setup completes).
    private var venvPython: URL { venvRoot.appendingPathComponent("bin/python") }

    /// Public accessor for the venv Python interpreter, for cooperating
    /// actors (e.g. ``TrackResolver``) that run their own subprocess using
    /// the same environment. `nil` until ``ensureReady()`` has actually
    /// built the venv.
    public var venvPythonURL: URL? {
        FileManager.default.isExecutableFile(atPath: venvPython.path) ? venvPython : nil
    }

    /// Public accessor for the bundled NTS `resolve_track.py` script
    /// (lives alongside `download.py` in the same bundle folder). Returns
    /// nil if the script can't be located (neither in the app bundle nor
    /// in the repo fallback).
    public var ntsResolverScriptURL: URL? {
        locateBundleScript(named: "resolve_track")
    }

    /// Bundled wrapper script. Looks in app bundle first, then repo during dev.
    private func locateWrapperScript() -> URL? {
        locateBundleScript(named: "download")
    }

    /// Shared lookup for any `.py` script that ships in the
    /// `spotify-downloader-bundle/` resource folder. Used by the download
    /// wrapper (`download.py`) and the NTS resolver (`resolve_track.py`).
    private func locateBundleScript(named name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "py",
                                          subdirectory: "spotify-downloader-bundle") {
            return bundled
        }
        // Dev fallback: walk up from CWD to find the repo
        var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cwd.appendingPathComponent("Vendor/spotify-downloader-bundle/\(name).py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cwd = cwd.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Setup entry points

    /// Fast check: does the venv exist and does `which ffmpeg` return something?
    public func checkSetup() async {
        setupState = .checking
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else {
            setupState = .unknown
            return
        }
        if !hasFFmpeg() {
            setupState = .failed("ffmpeg not found — install with `brew install ffmpeg`.")
            return
        }
        setupState = .ready
    }

    /// Create the venv if missing and pip install dependencies. Idempotent.
    /// Throws if ffmpeg is missing or pip fails.
    public func ensureReady() async throws {
        if case .ready = setupState { return }
        guard hasFFmpeg() else {
            let msg = "ffmpeg not found on PATH. Install with: brew install ffmpeg"
            setupState = .failed(msg)
            throw SetupError.ffmpegMissing
        }

        let fm = FileManager.default
        try fm.createDirectory(at: venvRoot.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        // spotapi requires Python 3.10+ (uses `X | None` union syntax).
        // macOS ships /usr/bin/python3 as 3.9.x, so we prefer Homebrew's
        // newer interpreters when available and fall back gracefully.
        guard let hostPython = Self.locateHostPython() else {
            let msg = "Python 3.10+ not found. Install via: brew install python@3.13"
            setupState = .failed(msg)
            throw SetupError.pythonTooOld
        }

        // If an existing venv was built against an older Python, scrap it
        // so we don't silently keep shipping broken imports.
        if fm.isExecutableFile(atPath: venvPython.path),
           !Self.venvIsCompatible(venvRoot: venvRoot) {
            setupState = .installing("Rebuilding Python environment…")
            try? fm.removeItem(at: venvRoot)
        }

        // Create venv if missing
        if !fm.isExecutableFile(atPath: venvPython.path) {
            setupState = .installing("Creating Python environment…")
            try await runBlocking(
                executable: hostPython,
                arguments: ["-m", "venv", venvRoot.path]
            )
        }

        // Upgrade pip (quiet — avoids noisy pip output)
        setupState = .installing("Updating pip…")
        try await runBlocking(
            executable: venvPython,
            arguments: ["-m", "pip", "install", "--quiet", "--upgrade", "pip"]
        )

        // Install download deps. spotapi's top-level `__init__` eagerly
        // imports modules that pull in session-store adapters (pymongo,
        // redis, readerwriterlock) and the websockets client — none of
        // which are declared as hard deps of the `spotapi` wheel. Pin
        // them explicitly so `from spotapi import ...` actually works.
        setupState = .installing("Installing downloader dependencies…")
        try await runBlocking(
            executable: venvPython,
            arguments: ["-m", "pip", "install", "--quiet",
                        "spotapi", "yt-dlp", "ytmusicapi",
                        "pymongo", "redis", "readerwriterlock",
                        "pyotp", "requests", "beautifulsoup4",
                        "mutagen", "websockets"]
        )

        setupState = .ready
        logger.info("downloader venv ready at \(self.venvRoot.path, privacy: .public)")
    }

    // MARK: - Enqueue

    @discardableResult
    public func enqueue(spotifyURL: URL, destination: URL) async throws -> Batch.ID {
        if case .ready = setupState {} else { try await ensureReady() }

        guard let wrapper = locateWrapperScript() else {
            throw DownloadError.wrapperMissing
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let batchID = UUID()
        var batch = Batch(
            id: batchID,
            url: spotifyURL,
            destination: destination,
            jobs: [],
            startedAt: Date()
        )
        batches.append(batch)

        let proc = Process()
        proc.executableURL = venvPython
        proc.arguments = [wrapper.path, "--url", spotifyURL.absoluteString,
                          "--output", destination.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            let code = p.terminationStatus
            Task { @MainActor in
                self.finishBatch(batchID, exitCode: code)
            }
        }

        do {
            try proc.run()
        } catch {
            logger.error("failed to start download subprocess: \(String(describing: error))")
            batch.errorMessage = error.localizedDescription
            batch.finishedAt = Date()
            updateBatch(batchID) { $0 = batch }
            throw error
        }

        processes[batchID] = proc

        // Drain stdout on a background task, parse events, post back on main
        Task.detached { [weak self] in
            guard let self else { return }
            await self.tailPipe(outPipe, batchID: batchID, stream: .stdout)
        }
        Task.detached { [weak self] in
            guard let self else { return }
            await self.tailPipe(errPipe, batchID: batchID, stream: .stderr)
        }

        return batchID
    }

    public func cancel(batchID: Batch.ID) {
        processes[batchID]?.terminate()
    }

    // MARK: - Pipe drain + event parsing

    private enum Stream { case stdout, stderr }

    private nonisolated func tailPipe(_ pipe: Pipe, batchID: Batch.ID, stream: Stream) async {
        let handle = pipe.fileHandleForReading
        var leftover = ""
        while true {
            let data: Data
            do {
                data = try handle.read(upToCount: 4096) ?? Data()
            } catch {
                break
            }
            if data.isEmpty { break }
            guard let chunk = String(data: data, encoding: .utf8) else { continue }
            leftover += chunk
            while let nlRange = leftover.firstRange(of: "\n") {
                let line = String(leftover[..<nlRange.lowerBound])
                leftover.removeSubrange(leftover.startIndex...nlRange.lowerBound)
                await self.ingest(line: line, batchID: batchID)
            }
        }
        if !leftover.isEmpty {
            await self.ingest(line: leftover, batchID: batchID)
        }
    }

    @MainActor
    private func ingest(line: String, batchID: Batch.ID) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logger.debug("[\(batchID.uuidString.prefix(8), privacy: .public)] \(trimmed, privacy: .public)")

        if let title = Self.parseMatching(trimmed) {
            upsertJob(batchID: batchID, title: title, status: .matching)
        } else if let title = Self.parseFound(trimmed) {
            upsertJob(batchID: batchID, title: title, status: .downloading)
        } else if let title = Self.parseNoMatch(trimmed) {
            upsertJob(batchID: batchID, title: title, status: .failed("no match on YouTube Music"))
        }
        // yt-dlp's own "[download] ..." lines could be parsed too, but core.py doesn't report per-track completion explicitly —
        // we'll mark tracks `.done` when the next `[MATCHING]` starts or the batch ends.
    }

    // MARK: - Regex parsers (nonisolated, pure)

    /// Parses `[MATCHING] Title` → "Title"
    nonisolated static func parseMatching(_ line: String) -> String? {
        parse(line: line, prefix: "[MATCHING] ")
    }

    /// Parses `[FOUND] Track title (https://...)` → "Track title"
    nonisolated static func parseFound(_ line: String) -> String? {
        guard let body = parse(line: line, prefix: "[FOUND] ") else { return nil }
        // Strip trailing " (URL)" if present
        if let parenIdx = body.lastIndex(of: "(") {
            return String(body[..<parenIdx]).trimmingCharacters(in: .whitespaces)
        }
        return body
    }

    /// Parses `[NO MATCH] Title` → "Title"
    nonisolated static func parseNoMatch(_ line: String) -> String? {
        parse(line: line, prefix: "[NO MATCH] ")
    }

    private nonisolated static func parse(line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = String(line.dropFirst(prefix.count))
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Batch/job mutation helpers

    private func upsertJob(batchID: Batch.ID, title: String, status: Job.Status) {
        updateBatch(batchID) { batch in
            if let idx = batch.jobs.firstIndex(where: { $0.title == title }) {
                batch.jobs[idx].status = status
            } else {
                // Mark the previous "downloading"/"matching" job done before starting a new one —
                // core.py processes tracks in batches but reports one line at a time.
                for i in batch.jobs.indices where batch.jobs[i].status == .downloading || batch.jobs[i].status == .matching {
                    batch.jobs[i].status = .done
                }
                batch.jobs.append(Job(id: UUID(), title: title, status: status))
            }
        }
    }

    private func finishBatch(_ batchID: Batch.ID, exitCode: Int32) {
        processes.removeValue(forKey: batchID)
        updateBatch(batchID) { batch in
            batch.finishedAt = Date()
            if exitCode != 0 {
                batch.errorMessage = "Downloader exited with code \(exitCode)"
            } else {
                // Mark any in-flight jobs as done
                for i in batch.jobs.indices where batch.jobs[i].status == .downloading || batch.jobs[i].status == .matching {
                    batch.jobs[i].status = .done
                }
            }
        }
        logger.info("batch \(batchID.uuidString.prefix(8), privacy: .public) finished (exit \(exitCode))")
    }

    private func updateBatch(_ batchID: Batch.ID, _ mutate: (inout Batch) -> Void) {
        guard let idx = batches.firstIndex(where: { $0.id == batchID }) else { return }
        mutate(&batches[idx])
    }

    // MARK: - Shell helpers

    private nonisolated func hasFFmpeg() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") ||
        FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg")
    }

    /// Find the newest Python 3.10+ interpreter on the system. macOS's
    /// `/usr/bin/python3` is pinned to 3.9.x which can't parse `X | None`
    /// union syntax that `spotapi` uses at import time, so we skip it
    /// unless nothing better exists (and then fail loudly in setup).
    nonisolated static func locateHostPython() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/python3.14",
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.10",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.14",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3.10",
            "/usr/local/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// True if the venv's Python is 3.10 or newer. An incompatible venv
    /// (built against the macOS-shipped 3.9) gets scrapped and rebuilt.
    nonisolated static func venvIsCompatible(venvRoot: URL) -> Bool {
        let libDir = venvRoot.appendingPathComponent("lib")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: libDir.path) else {
            return false
        }
        for name in entries where name.hasPrefix("python") {
            let version = String(name.dropFirst("python".count))
            if let major = version.split(separator: ".").first.flatMap({ Int($0) }),
               let minor = version.split(separator: ".").dropFirst().first.flatMap({ Int($0) }) {
                return major > 3 || (major == 3 && minor >= 10)
            }
        }
        return false
    }

    private nonisolated func runBlocking(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: SetupError.commandFailed(executable.lastPathComponent, proc.terminationStatus))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: - Errors

    public enum SetupError: Error, LocalizedError {
        case ffmpegMissing
        case pythonTooOld
        case commandFailed(String, Int32)
        public var errorDescription: String? {
            switch self {
            case .ffmpegMissing: return "ffmpeg not found"
            case .pythonTooOld: return "Python 3.10+ not found (install: brew install python@3.13)"
            case .commandFailed(let cmd, let code): return "\(cmd) failed with code \(code)"
            }
        }
    }

    public enum DownloadError: Error, LocalizedError {
        case wrapperMissing
        public var errorDescription: String? {
            switch self {
            case .wrapperMissing: return "download.py script not found in bundle"
            }
        }
    }
}
#endif
