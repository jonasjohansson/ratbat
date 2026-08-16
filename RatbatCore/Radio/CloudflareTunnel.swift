#if os(macOS)
import Foundation
import OSLog

/// Proxies a locally-bound radio stream out onto the public internet by
/// spawning `cloudflared` as a subprocess.
///
/// Two operating modes, picked automatically:
///
/// 1. **Quick tunnel** (default, zero-config): runs
///    `cloudflared tunnel --url http://localhost:<port>` and scrapes
///    the ephemeral `https://*.trycloudflare.com` URL from stderr. Works
///    without any Cloudflare account and comes up in a few seconds. The
///    URL changes every run — fine for "send this to my brother right
///    now", not fine for bookmarking.
///
/// 2. **Named tunnel**: if the user has already set up a tunnel via
///    `cloudflared tunnel login` + `cloudflared tunnel create` and has a
///    `~/.cloudflared/config.yml`, we instead run `cloudflared tunnel
///    run` which uses their stable hostname. We do a best-effort scan of
///    that YAML for the first `hostname:` line so the UI can show a URL;
///    if we can't find one, `publicURL` stays nil and the user checks
///    their own Cloudflare dashboard.
///
/// Why MainActor: `@Published` state is published straight to SwiftUI,
/// and `RadioBroadcaster` (also `@MainActor`) is the only caller. The
/// subprocess output reader runs as a detached task and hops back to the
/// actor to mutate state.
///
/// macOS-only. The iOS app will never spawn subprocesses for this — if
/// we want cross-platform public URLs later, that becomes a server-side
/// concern.
@MainActor
public final class CloudflareTunnel: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isRunning = false
    @Published public private(set) var publicURL: URL?
    @Published public private(set) var mode: Mode = .idle
    @Published public private(set) var error: String?

    /// What flavour of tunnel we're running. Lets the UI say "this URL
    /// will rotate" (quick) vs "this is your configured hostname" (named)
    /// without the caller having to sniff.
    public enum Mode: Sendable {
        case idle
        case starting
        /// Ephemeral `trycloudflare.com` URL — no account needed.
        case quick
        /// Stable URL from `~/.cloudflared/config.yml`.
        case named
    }

    /// The last few lines cloudflared printed, kept so an unexpected exit
    /// can be logged *with the reason attached*.
    ///
    /// The outage this guards against was undiagnosable after the fact:
    /// cloudflared's output went to `logger.debug`, which the unified log
    /// does not persist, so `log show` three days later returned nothing
    /// at all. Whatever it said as it died was gone.
    @Published public private(set) var recentOutput: [String] = []

    /// How many lines of cloudflared output to retain. Enough to carry the
    /// error and the retries around it; bounded so a tunnel up for weeks
    /// doesn't grow it forever.
    nonisolated public static let recentOutputLimit = 50

    /// A run of at least this long counts as "healthy" — a tunnel that
    /// dies after it is a fresh incident, not a continuing crash-loop, so
    /// the backoff starts over.
    nonisolated public static let stableRunSeconds: TimeInterval = 120

    // MARK: - Launch seam

    /// Handle on a launched cloudflared. Only the ability to stop it —
    /// everything else arrives through the callbacks.
    public struct ProcessHandle {
        public let terminate: @MainActor () -> Void
        public init(terminate: @escaping @MainActor () -> Void) {
            self.terminate = terminate
        }
    }

    /// Spawns cloudflared. Injectable so the supervision logic is testable
    /// without a real subprocess — the previous test file skipped the
    /// lifecycle entirely and deferred it to a manual check that never ran.
    public typealias Launcher = @MainActor (
        _ binary: URL,
        _ arguments: [String],
        _ onOutputLine: @escaping @Sendable (String) -> Void,
        _ onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> ProcessHandle

    /// Everything `start()` needs to learn from the machine it is running
    /// on, gathered behind one injectable seam.
    ///
    /// Injecting the *launcher* alone was not enough, and the way we found
    /// out is worth recording: these supervision tests passed on the
    /// developer's Mac and failed on the CI runner. `start()` resolves the
    /// binary before it ever reaches the launcher, so on a machine with no
    /// `cloudflared` it returned at the guard and the fake launcher was
    /// never called — the supervisor went untested precisely where it most
    /// needed testing. That is the same inside-the-box defect this whole
    /// pass exists to hunt, so the filesystem boundary is now a seam too.
    public struct Environment: Sendable {
        /// Where `cloudflared` lives, or nil if it isn't installed.
        public var locateBinary: @Sendable () -> URL?
        /// Whether `~/.cloudflared/config.yml` exists — picks named vs quick.
        public var namedTunnelConfigured: @Sendable () -> Bool
        /// First `hostname:` in that config, for the UI. May be nil even
        /// when a config exists (no hostname line), which is a real case.
        public var namedTunnelHostname: @Sendable () -> URL?

        public init(
            locateBinary: @escaping @Sendable () -> URL?,
            namedTunnelConfigured: @escaping @Sendable () -> Bool,
            namedTunnelHostname: @escaping @Sendable () -> URL?
        ) {
            self.locateBinary = locateBinary
            self.namedTunnelConfigured = namedTunnelConfigured
            self.namedTunnelHostname = namedTunnelHostname
        }

        /// What the app actually runs: real disk, real binary lookup.
        public static let live = Environment(
            locateBinary: { CloudflareTunnel.locateCloudflaredBinary() },
            namedTunnelConfigured: { CloudflareTunnel.namedTunnelConfigured() },
            namedTunnelHostname: { CloudflareTunnel.readFirstHostnameFromConfig() }
        )
    }

    // MARK: - Internals

    private var handle: ProcessHandle?
    private var restartTask: Task<Void, Never>?
    private var startedAt: Date?
    private var lastPort: UInt16?
    private var restartAttempt = 0
    /// Set across a deliberate `stop()` so the resulting exit callback
    /// isn't mistaken for a crash and answered with a relaunch.
    private var isStopping = false

    private let launcher: Launcher
    private let environment: Environment
    private let restartDelayOverride: TimeInterval?
    private let restartOnUnexpectedExit: Bool

    private let logger = Logger(
        subsystem: RatbatLog.subsystem,
        category: "tunnel"
    )

    /// - Parameters:
    ///   - launcher: how to spawn cloudflared. Defaults to a real `Process`.
    ///   - environment: what to learn from the host machine. Defaults to
    ///     real disk; override so lifecycle tests don't depend on whether
    ///     the machine happens to have cloudflared installed.
    ///   - restartDelayOverride: skip the backoff (tests only).
    ///   - restartOnUnexpectedExit: whether to supervise at all.
    public init(
        launcher: Launcher? = nil,
        environment: Environment = .live,
        restartDelayOverride: TimeInterval? = nil,
        restartOnUnexpectedExit: Bool = true
    ) {
        self.launcher = launcher ?? CloudflareTunnel.spawnProcess
        self.environment = environment
        self.restartDelayOverride = restartDelayOverride
        self.restartOnUnexpectedExit = restartOnUnexpectedExit
    }

    // MARK: - Restart policy (pure, so it's testable)

    /// Seconds to wait before relaunch attempt `attempt` (1-based).
    /// Doubles from 1s and caps at 30s: quick enough that a one-off crash
    /// is invisible to listeners, slow enough not to hammer a Cloudflare
    /// edge that is genuinely down.
    nonisolated public static func restartDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 1 }
        return min(30, pow(2, Double(attempt - 1)))
    }

    /// Next attempt number given how long the process that just died had
    /// been up. A long healthy run resets the escalation.
    nonisolated public static func nextAttempt(previous: Int, uptime: TimeInterval) -> Int {
        uptime >= stableRunSeconds ? 1 : previous + 1
    }

    // MARK: - Public API

    /// Start the tunnel, forwarding the public URL to `http://localhost:<localPort>`.
    /// No-op if already running. On failure, sets `error` and returns with
    /// `mode == .idle`.
    public func start(forwardingTo localPort: UInt16) async {
        guard !isRunning, handle == nil else { return }
        isStopping = false
        error = nil
        mode = .starting
        publicURL = nil
        lastPort = localPort

        guard let binary = environment.locateBinary() else {
            error = "cloudflared binary not found"
            mode = .idle
            return
        }

        let useNamed = environment.namedTunnelConfigured()
        let args: [String]
        if useNamed {
            // User has a config.yml; it should define ingress → localhost.
            args = ["tunnel", "run"]
        } else {
            args = ["tunnel", "--url", "http://localhost:\(localPort)"]
        }

        do {
            handle = try launcher(
                binary,
                args,
                { line in
                    Task { @MainActor [weak self] in self?.ingest(line: line) }
                },
                { code in
                    Task { @MainActor [weak self] in self?.handleExit(code: code) }
                }
            )
            startedAt = Date()
            isRunning = true
            mode = useNamed ? .named : .quick
            // `.notice`, not `.info`: the unified log does not persist
            // info-level messages to disk, which is why three days of
            // tunnel history amounted to zero retrievable lines.
            logger.notice(
                "cloudflared started, mode \(String(describing: self.mode), privacy: .public), forwarding to localhost:\(localPort, privacy: .public)"
            )
        } catch {
            self.error = "Failed to start cloudflared: \(error.localizedDescription)"
            mode = .idle
            logger.error(
                "cloudflared failed to start: \(error.localizedDescription, privacy: .public)"
            )
            scheduleRestart(afterUptime: 0)
            return
        }

        // For named-tunnel runs there's no trycloudflare.com URL to
        // scrape — the hostname lives in the user's config.yml. Try to
        // pull it out with a line-based scan so the UI has SOMETHING to
        // show without adding a YAML parser dependency.
        if useNamed, let named = environment.namedTunnelHostname() {
            self.publicURL = named
        }
    }

    /// Stop the tunnel. Idempotent — safe to call before `start`,
    /// mid-boot, or after a failure. Suppresses the supervisor, so the
    /// exit this causes is not answered with a relaunch.
    public func stop() {
        isStopping = true
        restartTask?.cancel()
        restartTask = nil
        handle?.terminate()
        handle = nil
        startedAt = nil
        restartAttempt = 0
        isRunning = false
        publicURL = nil
        mode = .idle
        logger.notice("cloudflared stopped (deliberate)")
    }

    // MARK: - Supervision

    /// cloudflared exited without us asking. Record *why* at a level that
    /// survives, then bring it back.
    private func handleExit(code: Int32) {
        guard !isStopping else { return }
        guard isRunning || handle != nil else { return }

        let uptime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        handle = nil
        startedAt = nil
        isRunning = false
        mode = .idle
        publicURL = nil

        let tail = recentOutput.suffix(10).joined(separator: " ⏎ ")
        logger.error(
            """
            cloudflared exited unexpectedly: status \(code, privacy: .public), \
            uptime \(Int(uptime), privacy: .public)s. Last output: \
            \(tail.isEmpty ? "<nothing captured>" : tail, privacy: .public)
            """
        )
        error = "cloudflared exited unexpectedly (status \(code))"

        scheduleRestart(afterUptime: uptime)
    }

    private func scheduleRestart(afterUptime uptime: TimeInterval) {
        guard restartOnUnexpectedExit, let port = lastPort else { return }

        restartAttempt = Self.nextAttempt(previous: restartAttempt, uptime: uptime)
        let delay = restartDelayOverride ?? Self.restartDelay(forAttempt: restartAttempt)
        logger.notice(
            "relaunching cloudflared in \(delay, privacy: .public)s (attempt \(self.restartAttempt, privacy: .public))"
        )

        restartTask?.cancel()
        restartTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.start(forwardingTo: port)
        }
    }

    /// Record one line of cloudflared output: retain it for diagnostics,
    /// scrape it for the quick-tunnel URL, and escalate anything that
    /// looks like an error to a log level that is actually persisted.
    private func ingest(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        recentOutput.append(trimmed)
        if recentOutput.count > Self.recentOutputLimit {
            recentOutput.removeFirst(recentOutput.count - Self.recentOutputLimit)
        }

        if let url = Self.extractPublicURL(from: trimmed) {
            publicURL = url
            logger.notice("tunnel URL: \(url.absoluteString, privacy: .public)")
        }

        if Self.looksLikeError(trimmed) {
            logger.error("[cloudflared] \(trimmed, privacy: .public)")
        } else {
            logger.debug("[cloudflared] \(trimmed, privacy: .public)")
        }
    }

    /// cloudflared tags its own severity (`ERR`, `WRN`, `FTL`). Match that
    /// rather than guessing from free text.
    nonisolated static func looksLikeError(_ line: String) -> Bool {
        // Match the severity as a whole token so it's found whether the
        // line is timestamp-prefixed ("…Z ERR Failed to…") or starts with
        // it outright. Substring matching on " ERR " misses the latter.
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for token in tokens where token == "ERR" || token == "WRN" || token == "FTL" {
            return true
        }
        let lower = line.lowercased()
        return lower.contains("failed to") || lower.contains("error=")
    }

    // MARK: - Binary / config discovery

    /// Where to find the `cloudflared` executable, in priority order:
    /// 1. Bundled inside `.app/Contents/Resources/` (shipping builds).
    /// 2. `Vendor/cloudflared/cloudflared` relative to cwd (dev/CLI).
    /// 3. Homebrew-style paths on PATH.
    /// Returns nil if nothing's found — caller must surface the error.
    ///
    /// `static` because we call it during init of the executable URL,
    /// before the instance has anything to lean on.
    nonisolated static func locateCloudflaredBinary() -> URL? {
        if let bundled = Bundle.main.url(forResource: "cloudflared", withExtension: nil) {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/cloudflared/cloudflared")
        if FileManager.default.isExecutableFile(atPath: dev.path) {
            return dev
        }
        for path in [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
        ] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Heuristic: if `~/.cloudflared/config.yml` exists we assume the
    /// user has a named tunnel ready to run. We don't validate the
    /// config — if it's broken, cloudflared will print an error we pass
    /// through to `error`.
    nonisolated static func namedTunnelConfigured() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent(".cloudflared/config.yml")
        return FileManager.default.fileExists(atPath: config.path)
    }

    /// Best-effort hostname extraction from `~/.cloudflared/config.yml`.
    /// Grabs the first `hostname: foo.bar.tld` line in the file, where
    /// "foo.bar.tld" is the bare DNS name. Returns an `https://` URL.
    ///
    /// We deliberately do NOT add a YAML parser — cloudflared configs are
    /// simple enough that a line-prefix match is fine, and in the failure
    /// case the user just doesn't see a clickable URL (functionally a no-op).
    ///
    /// `nonisolated` so tests (and the subprocess output reader, which
    /// runs in a detached task) can call it directly without an actor hop.
    nonisolated static func readFirstHostnameFromConfig() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent(".cloudflared/config.yml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else {
            return nil
        }
        return firstHostnameURL(in: text)
    }

    /// Pure function wrapped around the line-scan so tests can drive it
    /// without touching disk. Looks for the first line whose trimmed
    /// prefix is `hostname:` (after any leading `-` or whitespace),
    /// grabs the remainder, strips quotes, and returns it as `https://`.
    nonisolated static func firstHostnameURL(in yaml: String) -> URL? {
        for rawLine in yaml.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            // Strip list-item dash ("- hostname: foo") and whitespace.
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            if line.hasPrefix("-")  { line = String(line.dropFirst(1)) }
            line = line.trimmingCharacters(in: .whitespaces)

            guard line.lowercased().hasPrefix("hostname:") else { continue }
            var value = line.dropFirst("hostname:".count)
                .trimmingCharacters(in: .whitespaces)
            // Strip optional surrounding quotes.
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            // Trim trailing comment.
            if let hashIdx = value.firstIndex(of: "#") {
                value = String(value[..<hashIdx])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !value.isEmpty else { continue }
            return URL(string: "https://\(value)")
        }
        return nil
    }

    // MARK: - Output parsing

    /// The real launcher: spawn cloudflared as a subprocess, stream its
    /// stderr line by line, and report its exit.
    ///
    /// The important line here is `terminationHandler`. Without it nothing
    /// observed the process dying — it exited, `isRunning` stayed `true`,
    /// and the radio was dark until somebody happened to notice.
    @MainActor
    static func spawnProcess(
        binary: URL,
        arguments: [String],
        onOutputLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> ProcessHandle {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = arguments

        // cloudflared writes its banner + URL to stderr, progress logs to
        // stdout. We read stderr (where the interesting failures land) and
        // still drain stdout so a full pipe buffer can't wedge the child.
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { finished in
            onExit(finished.terminationStatus)
        }

        try proc.run()

        Self.streamLines(from: errPipe, to: onOutputLine)
        Self.streamLines(from: outPipe, to: onOutputLine)

        return ProcessHandle(terminate: {
            if proc.isRunning { proc.terminate() }
        })
    }

    /// Line-buffer a pipe on a background task, handing each complete line
    /// to `sink`. Ends at EOF, which is also when the child has gone.
    nonisolated private static func streamLines(
        from pipe: Pipe,
        to sink: @escaping @Sendable (String) -> Void
    ) {
        let handle = pipe.fileHandleForReading
        Task.detached {
            var buffer = ""
            while !Task.isCancelled {
                let data: Data
                do {
                    data = try handle.read(upToCount: 4096) ?? Data()
                } catch {
                    break
                }
                if data.isEmpty { break }
                guard let chunk = String(data: data, encoding: .utf8) else {
                    continue
                }
                buffer += chunk
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl])
                    buffer.removeSubrange(...nl)
                    sink(line)
                }
            }
        }
    }

    /// Scrape a `https://<subdomain>.trycloudflare.com` URL out of one
    /// line of cloudflared output. cloudflared prints the URL on its
    /// own line surrounded by `|` characters in an ASCII-art box; the
    /// regex doesn't care, it just matches the URL substring.
    nonisolated static func extractPublicURL(from line: String) -> URL? {
        let pattern = #"https://[A-Za-z0-9][A-Za-z0-9-]*\.trycloudflare\.com"#
        guard let range = line.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(line[range]))
    }

}
#endif
