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

    // MARK: - Internals

    private var process: Process?
    private var outputReader: Task<Void, Never>?
    private let logger = Logger(
        subsystem: "se.jonasjohansson.ratbat",
        category: "tunnel"
    )

    public init() {}

    // MARK: - Public API

    /// Start the tunnel, forwarding the public URL to `http://localhost:<localPort>`.
    /// No-op if already running. On failure, sets `error` and returns with
    /// `mode == .idle`.
    public func start(forwardingTo localPort: UInt16) async {
        guard !isRunning, process == nil else { return }
        error = nil
        mode = .starting
        publicURL = nil

        guard let binary = Self.locateCloudflaredBinary() else {
            error = "cloudflared binary not found"
            mode = .idle
            return
        }

        let useNamed = Self.namedTunnelConfigured()
        let args: [String]
        if useNamed {
            // User has a config.yml; it should define ingress → localhost.
            args = ["tunnel", "run"]
        } else {
            args = ["tunnel", "--url", "http://localhost:\(localPort)"]
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args

        // cloudflared writes its banner + URL to stderr, progress logs
        // to stdout. We hoover both up and merge via the parser.
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            process = proc
            isRunning = true
            mode = useNamed ? .named : .quick
            logger.info(
                "cloudflared started, mode \(String(describing: self.mode), privacy: .public)"
            )
        } catch {
            self.error = "Failed to start cloudflared: \(error.localizedDescription)"
            mode = .idle
            return
        }

        // For named-tunnel runs there's no trycloudflare.com URL to
        // scrape — the hostname lives in the user's config.yml. Try to
        // pull it out with a line-based scan so the UI has SOMETHING to
        // show without adding a YAML parser dependency.
        if useNamed, let named = Self.readFirstHostnameFromConfig() {
            self.publicURL = named
        }

        // Tail stderr looking for the quick-tunnel URL. Named mode never
        // emits one, but tailing is still useful so OSLog captures
        // cloudflared's connection-state logs for debugging.
        outputReader = Task.detached { [weak self] in
            await Self.tailOutput(pipe: errPipe, owner: self)
        }
    }

    /// Stop the tunnel. Idempotent — safe to call before `start`,
    /// mid-boot, or after a failure.
    public func stop() {
        outputReader?.cancel()
        outputReader = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        isRunning = false
        publicURL = nil
        mode = .idle
        logger.info("cloudflared stopped")
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
    nonisolated private static func locateCloudflaredBinary() -> URL? {
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
    nonisolated private static func namedTunnelConfigured() -> Bool {
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

    /// Stream-reads a pipe, line-buffers it, and for each line: (a) logs
    /// it via OSLog for debugging, (b) runs the URL regex and, on a hit,
    /// hops back to `MainActor` to publish `publicURL`.
    ///
    /// Runs until the pipe closes, EOF, or the owning task is cancelled.
    nonisolated private static func tailOutput(pipe: Pipe, owner: CloudflareTunnel?) async {
        let handle = pipe.fileHandleForReading
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
                if let url = extractPublicURL(from: line) {
                    await owner?.setPublicURL(url)
                }
                await owner?.logLine(line)
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

    fileprivate func setPublicURL(_ url: URL) async {
        publicURL = url
        logger.info("tunnel URL: \(url.absoluteString, privacy: .public)")
    }

    fileprivate func logLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        logger.debug("[cloudflared] \(trimmed, privacy: .public)")
    }
}
#endif
