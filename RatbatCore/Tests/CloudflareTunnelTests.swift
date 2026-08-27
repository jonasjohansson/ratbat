import XCTest
@testable import RatbatCore

/// Unit tests for `CloudflareTunnel`.
///
/// Deliberately does NOT spawn actual `cloudflared` subprocesses — that's
/// flaky in CI (network, binary availability, timing) and covered by the
/// manual verification step in the task plan. What we CAN test cheaply:
///
/// - Initial state matches the documented idle contract.
/// - The `https://*.trycloudflare.com` URL regex extracts URLs from
///   real-world cloudflared output lines and rejects look-alikes.
/// - The YAML line-scan for `~/.cloudflared/config.yml` pulls the first
///   `hostname:` value out of a handful of shapes the cloudflared docs
///   show (top-level, inside `ingress:`, quoted, with a list dash,
///   trailing comment).
final class CloudflareTunnelTests: XCTestCase {

    @MainActor
    func testInitialStateIsIdle() {
        let tunnel = CloudflareTunnel()
        XCTAssertFalse(tunnel.isRunning)
        XCTAssertNil(tunnel.publicURL)
        XCTAssertNil(tunnel.error)
        XCTAssertEqual(tunnel.mode, .idle)
    }

    // MARK: - Supervision
    //
    // These are the tests that were missing when the radio went dark for
    // days: cloudflared exited, `isRunning` stayed true, nothing relaunched
    // it and nothing recorded why. Reproduced by SIGKILLing the real
    // process — the public URL went 200 → 502 → 530 and stayed at 530.

    /// A machine that definitely has cloudflared and definitely has no
    /// named-tunnel config, regardless of the machine actually running the
    /// test.
    ///
    /// Without this the supervision tests were environment-dependent in a
    /// way that hid them exactly where they mattered: they passed on a dev
    /// Mac (bundled cloudflared present) and failed on the CI runner, where
    /// `start()` hit the "binary not found" guard and returned before the
    /// fake launcher was ever called. The path under test is the
    /// supervisor, not the host's `/opt/homebrew`.
    @MainActor
    private static func fakeEnvironment(
        binary: URL? = URL(fileURLWithPath: "/nonexistent/cloudflared"),
        named: Bool = false,
        hostname: URL? = nil
    ) -> CloudflareTunnel.Environment {
        CloudflareTunnel.Environment(
            locateBinary: { binary },
            namedTunnelConfigured: { named },
            namedTunnelHostname: { hostname }
        )
    }

    /// A fake launcher so the lifecycle is testable without spawning a
    /// real cloudflared (network, binary availability and timing make that
    /// hopeless in a unit test).
    @MainActor
    private final class FakeLauncher {
        private(set) var launches: [[String]] = []
        private(set) var terminateCount = 0
        var onExit: ((Int32) -> Void)?
        var emitLine: ((String) -> Void)?

        func launcher() -> CloudflareTunnel.Launcher {
            { [self] _, args, lineSink, exitSink in
                launches.append(args)
                onExit = { code in exitSink(code) }
                emitLine = { line in lineSink(line) }
                return CloudflareTunnel.ProcessHandle(
                    terminate: { [self] in terminateCount += 1 }
                )
            }
        }
    }

    // MARK: - The real subprocess path
    //
    // Everything above drives a fake launcher, which proves the policy but
    // not the plumbing — and the plumbing is exactly what was missing.
    // These two use the production `spawnProcess` against harmless
    // binaries, so the real `terminationHandler` and the real pipe reader
    // are the things under test.

    /// The production launcher must report a real process's exit. This is
    /// the line whose absence made the outage invisible.
    @MainActor
    func testRealSpawnReportsProcessExit() async throws {
        let exited = expectation(description: "terminationHandler fires")
        let status = UncheckedBox<Int32>(-1)

        _ = try CloudflareTunnel.spawnProcess(
            binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            onOutputLine: { _ in },
            onExit: { code in
                status.value = code
                exited.fulfill()
            }
        )

        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(status.value, 7, "exit status must be reported, not swallowed")
    }

    /// The production launcher must stream the child's stderr — that's how
    /// cloudflared's reason-for-dying reaches the log.
    @MainActor
    func testRealSpawnStreamsStderrLines() async throws {
        let sawLine = expectation(description: "stderr line observed")
        let seen = UncheckedBox<[String]>([])

        _ = try CloudflareTunnel.spawnProcess(
            binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'ERR something broke' 1>&2; sleep 0.2"],
            onOutputLine: { line in
                seen.value.append(line)
                if line.contains("something broke") { sawLine.fulfill() }
            },
            onExit: { _ in }
        )

        await fulfillment(of: [sawLine], timeout: 10)
        XCTAssertTrue(
            seen.value.contains(where: { CloudflareTunnel.looksLikeError($0) }),
            "an ERR line must be classified as an error so it is logged at a persisted level"
        )
    }

    /// Minimal mutable box for values crossing the launcher's `@Sendable`
    /// callbacks in tests.
    private final class UncheckedBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Backoff must grow so a hard-down Cloudflare isn't hammered, and cap
    /// so recovery after a long outage is still prompt.
    func testRestartBackoffGrowsAndCaps() {
        XCTAssertEqual(CloudflareTunnel.restartDelay(forAttempt: 1), 1)
        XCTAssertEqual(CloudflareTunnel.restartDelay(forAttempt: 2), 2)
        XCTAssertEqual(CloudflareTunnel.restartDelay(forAttempt: 3), 4)
        XCTAssertEqual(CloudflareTunnel.restartDelay(forAttempt: 4), 8)
        XCTAssertEqual(CloudflareTunnel.restartDelay(forAttempt: 10), 30, "capped")
        XCTAssertEqual(CloudflareTunnel.restartDelay(forAttempt: 999), 30, "still capped")
    }

    /// A tunnel that ran healthily for a long time and then died is a
    /// fresh incident, not an escalation — its retry starts from 1 again.
    /// A crash-loop keeps escalating.
    func testAttemptCounterResetsAfterAStableRun() {
        XCTAssertEqual(CloudflareTunnel.nextAttempt(previous: 5, uptime: 600), 1, "stable run resets")
        XCTAssertEqual(CloudflareTunnel.nextAttempt(previous: 5, uptime: 0.5), 6, "crash loop escalates")
        XCTAssertEqual(CloudflareTunnel.nextAttempt(previous: 0, uptime: 0), 1)
    }

    /// The core regression: when cloudflared exits on its own, the tunnel
    /// must notice, drop `isRunning`, and relaunch.
    @MainActor
    func testUnexpectedExitRelaunchesCloudflared() async throws {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(),
            restartDelayOverride: 0
        )
        await tunnel.start(forwardingTo: 18_000)

        XCTAssertTrue(tunnel.isRunning)
        XCTAssertEqual(fake.launches.count, 1)

        fake.onExit?(137)  // SIGKILL, exactly what we did to the real one

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(fake.launches.count, 2, "cloudflared must be relaunched after an unexpected exit")
        XCTAssertTrue(tunnel.isRunning, "isRunning must reflect the relaunched process")
    }

    /// `isRunning` must never claim a dead process is alive — that lie is
    /// what made the outage invisible from inside the app.
    @MainActor
    func testIsRunningGoesFalseOnExitWhenRestartDisabled() async throws {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(),
            restartDelayOverride: 0,
            restartOnUnexpectedExit: false
        )
        await tunnel.start(forwardingTo: 18_000)
        XCTAssertTrue(tunnel.isRunning)

        fake.onExit?(1)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(tunnel.isRunning)
        XCTAssertEqual(fake.launches.count, 1, "must not relaunch when supervision is off")
        XCTAssertNotNil(tunnel.error, "an unexpected exit is an error the UI can show")
    }

    /// A deliberate `stop()` must not trigger the supervisor — otherwise
    /// quitting the app would fight a relaunch loop.
    @MainActor
    func testDeliberateStopDoesNotRelaunch() async throws {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(),
            restartDelayOverride: 0
        )
        await tunnel.start(forwardingTo: 18_000)

        tunnel.stop()
        fake.onExit?(0)  // the terminate we asked for lands afterwards

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(fake.launches.count, 1, "stop() must not be followed by a relaunch")
        XCTAssertFalse(tunnel.isRunning)
        XCTAssertEqual(tunnel.mode, .idle)
        XCTAssertEqual(fake.terminateCount, 1)
    }

    /// The absence of evidence was itself a defect: when the tunnel died,
    /// nothing survived to say why. Keep cloudflared's recent output so the
    /// exit can be logged with context.
    @MainActor
    func testRecentOutputIsRetainedForDiagnostics() async throws {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(),
            restartDelayOverride: 0,
            restartOnUnexpectedExit: false
        )
        await tunnel.start(forwardingTo: 18_000)

        fake.emitLine?("2026-08-09T17:00:00Z ERR Failed to serve quic connection error=\"timeout\"")
        fake.emitLine?("2026-08-09T17:00:01Z INF Retrying connection in 1s")
        try await Task.sleep(nanoseconds: 100_000_000)

        let tail = tunnel.recentOutput
        XCTAssertTrue(
            tail.contains(where: { $0.contains("Failed to serve quic connection") }),
            "cloudflared's own error lines must be retained, got: \(tail)"
        )
        XCTAssertLessThanOrEqual(tail.count, CloudflareTunnel.recentOutputLimit)
    }

    /// The retained buffer is bounded — a tunnel up for weeks must not
    /// grow it without limit.
    @MainActor
    func testRecentOutputIsBounded() async throws {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(),
            restartDelayOverride: 0
        )
        await tunnel.start(forwardingTo: 18_000)

        for i in 0..<(CloudflareTunnel.recentOutputLimit * 3) {
            fake.emitLine?("line \(i)")
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(tunnel.recentOutput.count, CloudflareTunnel.recentOutputLimit)
        XCTAssertTrue(tunnel.recentOutput.last?.contains("line \(CloudflareTunnel.recentOutputLimit * 3 - 1)") ?? false,
                      "must keep the most recent lines, not the oldest")
    }

    // MARK: - Environment handling
    //
    // The seam these drive is the one that made the supervision tests
    // machine-dependent. Now that it's injectable, both sides of every
    // branch are reachable on any runner, so cover them.

    /// No cloudflared on the box: `start()` must fail loudly and stay idle
    /// rather than reporting a tunnel it never launched.
    @MainActor
    func testMissingBinaryFailsWithoutLaunching() async {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(binary: nil),
            restartDelayOverride: 0
        )
        await tunnel.start(forwardingTo: 18_000)

        XCTAssertEqual(fake.launches.count, 0, "nothing to launch")
        XCTAssertFalse(tunnel.isRunning)
        XCTAssertEqual(tunnel.mode, .idle)
        XCTAssertEqual(tunnel.error, "cloudflared binary not found")
    }

    /// Quick-tunnel mode: no config.yml, so forward the local port on the
    /// command line and expect the URL to be scraped from stderr.
    @MainActor
    func testQuickTunnelPassesLocalPortOnCommandLine() async {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(named: false),
            restartDelayOverride: 0
        )
        await tunnel.start(forwardingTo: 18_000)

        XCTAssertEqual(fake.launches.first, ["tunnel", "--url", "http://localhost:18000"])
        XCTAssertEqual(tunnel.mode, .quick)
        XCTAssertNil(tunnel.publicURL, "quick-tunnel URL only arrives via stderr")
    }

    /// Named-tunnel mode: a config.yml is present, so run it and show the
    /// hostname the config declares. This is the mac-mini's actual shape —
    /// radio.jonasjohansson.se comes from config.yml, not from stderr.
    @MainActor
    func testNamedTunnelRunsConfigAndSurfacesHostname() async {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(
                named: true,
                hostname: URL(string: "https://radio.jonasjohansson.se")
            ),
            restartDelayOverride: 0
        )
        await tunnel.start(forwardingTo: 18_000)

        XCTAssertEqual(fake.launches.first, ["tunnel", "run"])
        XCTAssertEqual(tunnel.mode, .named)
        XCTAssertEqual(tunnel.publicURL?.absoluteString, "https://radio.jonasjohansson.se")
    }

    /// A config.yml with no `hostname:` line is a real case — run the
    /// named tunnel anyway, just without a URL to show.
    @MainActor
    func testNamedTunnelWithoutHostnameStillRuns() async {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(named: true, hostname: nil),
            restartDelayOverride: 0
        )
        await tunnel.start(forwardingTo: 18_000)

        XCTAssertEqual(fake.launches.first, ["tunnel", "run"])
        XCTAssertEqual(tunnel.mode, .named)
        XCTAssertNil(tunnel.publicURL)
    }

    // MARK: - URL extraction

    func testExtractPublicURLFromBannerLine() {
        // Shape cloudflared actually prints — URL embedded in a box-drawn
        // banner surrounded by pipes and whitespace.
        let line = "|  https://purple-mouse-47.trycloudflare.com                      |"
        let url = CloudflareTunnel.extractPublicURL(from: line)
        XCTAssertEqual(url?.absoluteString, "https://purple-mouse-47.trycloudflare.com")
    }

    func testExtractPublicURLFromLogLine() {
        // Some cloudflared versions log it as a structured log entry.
        let line = "2026-04-16T10:00:00Z INF Your quick tunnel has been created! Visit it at: https://foo-bar-baz.trycloudflare.com"
        let url = CloudflareTunnel.extractPublicURL(from: line)
        XCTAssertEqual(url?.absoluteString, "https://foo-bar-baz.trycloudflare.com")
    }

    func testExtractPublicURLRejectsNonMatching() {
        // Other https URLs must not be picked up — we're specifically
        // looking for the trycloudflare.com domain.
        XCTAssertNil(CloudflareTunnel.extractPublicURL(
            from: "connecting to https://region2.argotunnel.com"
        ))
        XCTAssertNil(CloudflareTunnel.extractPublicURL(
            from: "no URL on this line at all"
        ))
    }

    // MARK: - config.yml hostname scan

    func testHostnameExtractionFromIngressStyleConfig() {
        let yaml = """
        tunnel: 12345
        credentials-file: /Users/jonas/.cloudflared/12345.json

        ingress:
          - hostname: radio.jonasjohansson.se
            service: http://localhost:18000
          - service: http_status:404
        """
        let url = CloudflareTunnel.firstHostnameURL(in: yaml)
        XCTAssertEqual(url?.absoluteString, "https://radio.jonasjohansson.se")
    }

    func testHostnameExtractionFromQuotedValue() {
        let yaml = """
        ingress:
          - hostname: "radio.example.com"
            service: http://localhost:18000
        """
        let url = CloudflareTunnel.firstHostnameURL(in: yaml)
        XCTAssertEqual(url?.absoluteString, "https://radio.example.com")
    }

    func testHostnameExtractionWithTrailingComment() {
        let yaml = """
        ingress:
          - hostname: radio.example.com # primary
            service: http://localhost:18000
        """
        let url = CloudflareTunnel.firstHostnameURL(in: yaml)
        XCTAssertEqual(url?.absoluteString, "https://radio.example.com")
    }

    func testHostnameExtractionReturnsNilWhenMissing() {
        let yaml = """
        tunnel: 12345
        credentials-file: /Users/jonas/.cloudflared/12345.json
        """
        XCTAssertNil(CloudflareTunnel.firstHostnameURL(in: yaml))
    }

    func testHostnameExtractionPicksFirstOfMany() {
        // We only promise the FIRST hostname — multi-hostname configs
        // can't be displayed meaningfully in a single-line caption
        // anyway, and for the common case (one ingress rule) this is
        // the right answer.
        let yaml = """
        ingress:
          - hostname: radio.example.com
            service: http://localhost:18000
          - hostname: other.example.com
            service: http://localhost:19000
        """
        let url = CloudflareTunnel.firstHostnameURL(in: yaml)
        XCTAssertEqual(url?.absoluteString, "https://radio.example.com")
    }

    // MARK: - Pipe line assembly

    /// Tunnel output used to arrive ~13 minutes late (measured: emitted
    /// 18:24:35, logged 18:38:00) because the reader waited on a blocking
    /// 4096-byte read. These cover the assembly rules of its replacement.

    func testAssemblesLinesAcrossChunkBoundaries() {
        let b = CloudflareTunnel.LineBuffer()
        XCTAssertEqual(b.append(Data("INF star".utf8)), [], "no newline yet, nothing to emit")
        XCTAssertEqual(b.append(Data("ted\nINF next\n".utf8)), ["INF started", "INF next"])
    }

    /// The old reader decoded each raw chunk with String(data:encoding:)
    /// and `continue`d on nil, so a read that split a multi-byte character
    /// discarded the entire chunk. Splitting on the newline byte first
    /// makes that unrepresentable.
    func testDoesNotDropAChunkThatSplitsAMultiByteCharacter() {
        let b = CloudflareTunnel.LineBuffer()
        let full = Array("hej så mycket\n".utf8)          // 'å' is two bytes
        let cut = full.firstIndex(of: 0xC3)!               // split mid-character
        XCTAssertEqual(b.append(Data(full[..<(cut + 1)])), [], "half a character is not a line")
        XCTAssertEqual(b.append(Data(full[(cut + 1)...])), ["hej så mycket"], "chunk must not be lost")
    }

    func testEmitsEachLineOnceForAMultiLineChunk() {
        let b = CloudflareTunnel.LineBuffer()
        XCTAssertEqual(b.append(Data("a\nb\nc\n".utf8)), ["a", "b", "c"])
        XCTAssertEqual(b.append(Data()), [], "empty append yields nothing")
    }

    func testStripsCarriageReturn() {
        let b = CloudflareTunnel.LineBuffer()
        XCTAssertEqual(b.append(Data("windows\r\n".utf8)), ["windows"])
    }

    /// cloudflared can die mid-line; that last fragment is often the most
    /// interesting thing it ever said, so EOF must flush it.
    func testRemainderIsFlushedAtEOF() {
        let b = CloudflareTunnel.LineBuffer()
        XCTAssertEqual(b.append(Data("ERR dying".utf8)), [])
        XCTAssertEqual(b.takeRemainder(), "ERR dying")
        XCTAssertNil(b.takeRemainder(), "remainder is consumed once")
    }

    func testNoRemainderWhenEverythingWasAWholeLine() {
        let b = CloudflareTunnel.LineBuffer()
        _ = b.append(Data("done\n".utf8))
        XCTAssertNil(b.takeRemainder())
    }

    // MARK: - Liveness (a tunnel that is running but not serving)

    /// The wedge, driven through the real runtime path: probe -> decide ->
    /// restart. Reproduced live with `kill -STOP` on cloudflared, where the
    /// process stays up so nothing exits and the exit-driven supervisor
    /// never fires.
    @MainActor
    func testWedgedTunnelIsDetectedAndRestarted() async throws {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(named: true,
                                              hostname: URL(string: "https://radio.example.com")),
            restartDelayOverride: 0
        )
        tunnel.probeOverride = { _, _ in (true, .tunnelSuspect(status: 530)) }
        await tunnel.start(forwardingTo: 18_000)
        XCTAssertEqual(fake.launches.count, 1)

        let url = URL(string: "https://radio.example.com")!
        await tunnel.probeOnce(publicURL: url, port: 18_000)
        XCTAssertEqual(fake.launches.count, 1, "one bad sample must not act")
        await tunnel.probeOnce(publicURL: url, port: 18_000)
        XCTAssertEqual(fake.launches.count, 1, "two is still not enough")
        await tunnel.probeOnce(publicURL: url, port: 18_000)

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fake.launches.count, 2, "third consecutive failure must restart the tunnel")
    }

    /// Both ends down is our fault, not the tunnel's. Restarting it would
    /// take the radio off air to fix a problem it does not have.
    @MainActor
    func testWedgeDetectorRefusesWhenLocalIsAlsoDown() async throws {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(named: true,
                                              hostname: URL(string: "https://radio.example.com")),
            restartDelayOverride: 0
        )
        tunnel.probeOverride = { _, _ in (false, .tunnelSuspect(status: 530)) }
        await tunnel.start(forwardingTo: 18_000)

        let url = URL(string: "https://radio.example.com")!
        for _ in 0..<8 { await tunnel.probeOnce(publicURL: url, port: 18_000) }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fake.launches.count, 1, "must never restart while the origin itself is down")
    }

    /// A healthy tunnel must never be restarted, however long it runs.
    @MainActor
    func testHealthyTunnelIsNeverRestarted() async throws {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(named: true,
                                              hostname: URL(string: "https://radio.example.com")),
            restartDelayOverride: 0
        )
        tunnel.probeOverride = { _, _ in (true, .ok) }
        await tunnel.start(forwardingTo: 18_000)

        let url = URL(string: "https://radio.example.com")!
        for _ in 0..<40 { await tunnel.probeOnce(publicURL: url, port: 18_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.launches.count, 1)
        XCTAssertTrue(tunnel.isRunning)
    }

    /// A *wedged* tunnel must still be killable.
    ///
    /// `Process.terminate()` sends SIGTERM. A stopped process cannot run a
    /// signal *handler*, so a handled SIGTERM stays pending — and
    /// cloudflared handles SIGTERM ("Initiating graceful shutdown due to
    /// signal terminated"). Restarting a SIGSTOPped cloudflared therefore
    /// left the frozen one running indefinitely, which is how this was
    /// found: the liveness probe restarted correctly and the old process
    /// was still there afterwards in state T.
    ///
    /// The stand-in installs a TERM trap for exactly that reason. A process
    /// with the *default* disposition (`/bin/sleep`) is killed by SIGTERM
    /// even while stopped, so it cannot tell the two implementations apart
    /// and would make this test vacuous.
    @MainActor
    func testTerminateKillsAWedgedProcessThatHandlesSIGTERM() async throws {
        // Run the trap inline under /bin/sh so `ps comm=` reports a path we
        // can match — for a script file it reports the interpreter instead.
        let handle = try CloudflareTunnel.spawnProcess(
            binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap 'exit 0' TERM; while : ; do /bin/sleep 1; done"],
            onOutputLine: { _ in },
            onExit: { _ in }
        )
        let me = ProcessInfo.processInfo.processIdentifier
        let pid = try XCTUnwrap(
            TunnelReaper.snapshotProcesses()
                .filter { $0.executablePath == "/bin/sh" && $0.parentPID == me }
                .last?.pid,
            "spawned helper not found in the process table"
        )
        // Freeze it: the wedge, reproduced in miniature.
        XCTAssertEqual(kill(pid, SIGSTOP), 0)
        var state = ""
        for _ in 0..<10 where !state.hasPrefix("T") {
            state = Self.processState(pid) ?? ""
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        handle.terminate()

        let deadline = Date().addingTimeInterval(CloudflareTunnel.terminateGraceSeconds + 10)
        while Date() < deadline {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertNotEqual(
            kill(pid, 0), 0,
            "a wedged tunnel must still be terminated, not left running forever"
        )
    }

    private static func processState(_ pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "stat=", "-p", "\(pid)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tunnel that exits *after* its replacement has started must not be
    /// mistaken for the replacement crashing.
    ///
    /// This is how a liveness restart ended up with two cloudflareds serving
    /// one tunnel: `stop()` sets `isStopping`, `start()` clears it, and the
    /// old process — wedged, so it needed SIGCONT before it could even act
    /// on SIGTERM — did not actually exit until after that pair had run. The
    /// late exit read as a crash and the supervisor launched another.
    @MainActor
    func testLateExitOfAReplacedProcessDoesNotSpawnADuplicate() async throws {
        let fake = FakeLauncher()
        let tunnel = CloudflareTunnel(
            launcher: fake.launcher(),
            environment: Self.fakeEnvironment(),
            restartDelayOverride: 0
        )
        await tunnel.start(forwardingTo: 18_000)
        XCTAssertEqual(fake.launches.count, 1)
        let staleExit = fake.onExit                 // generation 1's callback

        // Replace it, the way a liveness restart does.
        tunnel.stop()
        await tunnel.start(forwardingTo: 18_000)
        XCTAssertEqual(fake.launches.count, 2)

        // Generation 1 finally dies, long after generation 2 is serving.
        staleExit?(143)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(
            fake.launches.count, 2,
            "a superseded process exiting must not be answered with another launch"
        )
        XCTAssertTrue(tunnel.isRunning, "the live tunnel must be left alone")
    }
}
