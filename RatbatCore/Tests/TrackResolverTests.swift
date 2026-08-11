#if os(macOS)
import XCTest
@testable import RatbatCore

/// Records what the resolver asked the outside world to do, and answers
/// with a canned result.
///
/// Substituting this for ``TrackResolver/spawnSubprocess`` is what lets the
/// resolve tests below run at all. They used to hand the resolver a bash
/// script as a stand-in for the venv Python, which meant every one of them
/// spawned a real process — and `Process.waitUntilExit()` permanently hung
/// roughly one invocation in thirty, wedging CI until the six-hour job
/// timeout killed it. The production hang is fixed in ``TrackResolver``;
/// these tests no longer depend on process spawning at all, because the
/// behaviour they care about is argument construction and result handling,
/// not whether the host can fork.
private final class RecordingRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [TrackResolver.Invocation] = []

    /// Canned reply. Defaults to the wrapper's success shape.
    var stdout = Data(#"{"youtube_id": "ytid123", "matched_title": "Match"}"#.utf8)
    var stderr = Data()
    var exitCode: Int32 = 0

    /// Whether to honour `--output` by writing a one-byte file there, the
    /// way a real download would. The resolver post-checks that the file
    /// landed, so this is part of the contract being exercised.
    var writesOutputFile = true

    var arguments: [String] {
        lock.lock()
        defer { lock.unlock() }
        return invocations.last?.arguments ?? []
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations.count
    }

    /// Synchronous so the locking stays out of an async context, where
    /// `NSLock.lock()` is unavailable.
    private func record(_ invocation: TrackResolver.Invocation) -> (Bool, TrackResolver.Output) {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(invocation)
        return (writesOutputFile, TrackResolver.Output(stdout: stdout, stderr: stderr, exitCode: exitCode))
    }

    func makeRunner() -> TrackResolver.Runner {
        { [self] invocation, _ in
            let (writes, result) = record(invocation)
            if writes, let path = invocation.outputPath {
                try Data([0x78]).write(to: URL(fileURLWithPath: path))
            }
            return result
        }
    }
}

/// Scaffolding tests for ``TrackResolver``.
///
/// We don't actually hit YouTube here — the happy path needs network,
/// a real venv, and ffmpeg. These tests exercise the service plumbing:
/// init creates the cache dir, cache size/listing primitives reflect
/// the filesystem, `prune` removes files, and the resolve paths build the
/// right argv and handle what comes back.
final class TrackResolverTests: XCTestCase {

    /// A temp dir cleaned up when the test ends, whatever the outcome.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Paths that satisfy the resolver's up-front existence checks. Nothing
    /// is ever executed — the injected runner stands in for the subprocess.
    private func makeStubPaths(in root: URL) throws -> (python: URL, wrapper: URL) {
        let wrapper = root.appendingPathComponent("resolve_track.py")
        try Data().write(to: wrapper)
        return (URL(fileURLWithPath: "/bin/echo"), wrapper)
    }

    func testInitCreatesCacheRoot() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),  // never called here
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: tempRoot
        )
        let cacheRoot = await resolver.cacheRoot
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.path))
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testCacheSizeReflectsFiles() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: tempRoot
        )
        let cacheRoot = await resolver.cacheRoot
        let file = cacheRoot.appendingPathComponent("x.m4a")
        let data = Data(repeating: 0xA5, count: 4096)
        try data.write(to: file)
        let size = try await resolver.cacheSize()
        XCTAssertEqual(size, 4096)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testCacheSizeIsZeroForEmptyDir() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: tempRoot
        )
        let size = try await resolver.cacheSize()
        XCTAssertEqual(size, 0)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testCachedFilesOldestFirstOrder() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: tempRoot
        )
        let cacheRoot = await resolver.cacheRoot

        let old = cacheRoot.appendingPathComponent("old.m4a")
        let new = cacheRoot.appendingPathComponent("new.m4a")
        try Data([0x00]).write(to: old)
        try Data([0x00]).write(to: new)

        // Force modification dates apart so sorting is deterministic.
        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        let newDate = Date(timeIntervalSince1970: 2_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: new.path)

        let ordered = try await resolver.cachedFilesOldestFirst()
        XCTAssertEqual(ordered.map { $0.lastPathComponent }, ["old.m4a", "new.m4a"])
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testPruneDeletesFile() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: tempRoot
        )
        let cacheRoot = await resolver.cacheRoot
        let file = cacheRoot.appendingPathComponent("x.m4a")
        try Data([0x00]).write(to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try await resolver.prune(at: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testResolveFailsWhenVenvPythonMissing() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/nonexistent/python"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: tempRoot
        )
        do {
            _ = try await resolver.resolve(artist: "A", title: "B")
            XCTFail("expected venvNotReady")
        } catch TrackResolver.Error.venvNotReady {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testResolveFailsWhenWrapperScriptMissing() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),  // exists, executable
            wrapperScript: URL(fileURLWithPath: "/nonexistent/resolve_track.py"),
            cacheRoot: tempRoot
        )
        do {
            _ = try await resolver.resolve(artist: "A", title: "B")
            XCTFail("expected resolverScriptMissing")
        } catch TrackResolver.Error.resolverScriptMissing {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Direct-URL path: when a ``SourceCandidate`` carries ``resolvedURL``
    /// the resolver should invoke the wrapper with `--source-url <url>`
    /// and emit the wrapper's synthetic id back through ``Resolution``.
    func testResolveWithCandidateInvokesDirectURLPath() async throws {
        let tempRoot = try makeTempRoot()
        let paths = try makeStubPaths(in: tempRoot)

        let runner = RecordingRunner()
        runner.stdout = Data(#"{"youtube_id": "bandcamp:stub-id", "matched_title": "Stub Title"}"#.utf8)

        let resolver = try TrackResolver(
            venvPython: paths.python,
            wrapperScript: paths.wrapper,
            cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true),
            runner: runner.makeRunner()
        )

        let bandcampURL = URL(string: "https://artist.bandcamp.com/track/some-song")!
        let candidate = SourceCandidate(
            artist: "Stub Artist",
            title: "Stub Title",
            resolvedURL: bandcampURL
        )
        let resolution = try await resolver.resolve(candidate: candidate)

        XCTAssertEqual(resolution.youtubeID, "bandcamp:stub-id")
        XCTAssertEqual(resolution.matchedTitle, "Stub Title")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.cachedURL.path))

        // The direct-URL branch was taken, not the search path.
        let argv = runner.arguments
        XCTAssertTrue(argv.contains("--source-url"), "argv missing --source-url: \(argv)")
        XCTAssertTrue(argv.contains(bandcampURL.absoluteString), "argv missing Bandcamp URL: \(argv)")
    }

    /// After a resolve, the cache is trimmed back under `cacheCapBytes`:
    /// the oldest files are evicted while the freshly-written file (and
    /// enough recent runway) survives. The cache is pre-seeded with old
    /// files that blow past a deliberately tiny cap.
    func testResolveEvictsOldestOverCacheCap() async throws {
        let tempRoot = try makeTempRoot()
        let paths = try makeStubPaths(in: tempRoot)

        let cacheRoot = tempRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        // Seed five 100-byte "old" files, well over a 100-byte cap.
        var oldFiles: [URL] = []
        for i in 0..<5 {
            let f = cacheRoot.appendingPathComponent("old-\(i).m4a")
            try Data(repeating: 0xA5, count: 100).write(to: f)
            // Push their mod dates into the past so they sort oldest-first.
            let date = Date(timeIntervalSince1970: TimeInterval(1_000_000 + i))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: f.path)
            oldFiles.append(f)
        }

        let resolver = try TrackResolver(
            venvPython: paths.python,
            wrapperScript: paths.wrapper,
            cacheRoot: cacheRoot,
            cacheCapBytes: 100,
            runner: RecordingRunner().makeRunner()
        )

        let resolution = try await resolver.resolve(artist: "A", title: "B")

        // The just-written file survives, the cache is back under cap, and
        // the seeded old files were the ones evicted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.cachedURL.path))
        let size = try await resolver.cacheSize()
        XCTAssertLessThanOrEqual(size, 100)
        for f in oldFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.path), "old file not evicted: \(f.lastPathComponent)")
        }
    }

    /// Candidate without a ``resolvedURL`` should route through the
    /// existing search path — no `--source-url` argument on the wrapper.
    func testResolveWithCandidateFallsBackToSearchPath() async throws {
        let tempRoot = try makeTempRoot()
        let paths = try makeStubPaths(in: tempRoot)

        let runner = RecordingRunner()
        let resolver = try TrackResolver(
            venvPython: paths.python,
            wrapperScript: paths.wrapper,
            cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true),
            runner: runner.makeRunner()
        )

        let candidate = SourceCandidate(artist: "A", title: "B") // no resolvedURL
        let resolution = try await resolver.resolve(candidate: candidate)

        XCTAssertEqual(resolution.youtubeID, "ytid123")

        let argv = runner.arguments
        XCTAssertFalse(argv.contains("--source-url"), "search path must not pass --source-url: \(argv)")
        // ...and it did ask for the artist/title it was given.
        XCTAssertTrue(argv.contains("A"), "argv missing artist: \(argv)")
        XCTAssertTrue(argv.contains("B"), "argv missing title: \(argv)")
    }

    /// The resolver hands its timeout down to the runner, and surfaces a
    /// runner timeout as ``TrackResolver/Error/timedOut(seconds:)`` rather
    /// than something the station loop can't recognise.
    func testResolveSurfacesRunnerTimeout() async throws {
        let tempRoot = try makeTempRoot()
        let paths = try makeStubPaths(in: tempRoot)

        let seen = TimeoutBox()
        let resolver = try TrackResolver(
            venvPython: paths.python,
            wrapperScript: paths.wrapper,
            cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true),
            timeout: .seconds(7),
            runner: { _, timeout in
                seen.value = timeout
                throw TrackResolver.Error.timedOut(seconds: Int(timeout.components.seconds))
            }
        )

        do {
            _ = try await resolver.resolve(artist: "A", title: "B")
            XCTFail("expected timedOut")
        } catch TrackResolver.Error.timedOut(let seconds) {
            XCTAssertEqual(seconds, 7)
        }
        XCTAssertEqual(seen.value, .seconds(7), "resolver did not pass its timeout to the runner")
    }

    /// The real runner kills a child that overruns the timeout, instead of
    /// waiting on it forever.
    ///
    /// This is the regression test for the hang that used to wedge CI for
    /// six hours: `sleep 30` under a one-second timeout must come back as a
    /// timeout in about a second. The `expectation` wrapper is deliberate —
    /// if the bound ever breaks again, this fails in 20 seconds with a
    /// message rather than hanging the job until the workflow is cancelled.
    func testSpawnSubprocessKillsChildPastTimeout() async throws {
        let finished = expectation(description: "runner returned")
        let outcome = ErrorBox()

        Task {
            let invocation = TrackResolver.Invocation(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"]
            )
            do {
                _ = try await TrackResolver.spawnSubprocess(invocation, .seconds(1))
            } catch {
                outcome.value = error
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 20)
        XCTAssertEqual(outcome.value as? TrackResolver.Error, .timedOut(seconds: 1))
    }

    /// The real runner reports a fast, well-behaved child correctly — the
    /// happy path of the same code the timeout test bounds.
    func testSpawnSubprocessCapturesOutputAndExitCode() async throws {
        let invocation = TrackResolver.Invocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf hello; printf oops >&2; exit 3"]
        )
        let output = try await TrackResolver.spawnSubprocess(invocation, .seconds(30))
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "hello")
        XCTAssertEqual(String(data: output.stderr, encoding: .utf8), "oops")
        XCTAssertEqual(output.exitCode, 3)
    }
}

/// Tiny lock-free-enough boxes so the closures above can hand a value back
/// out without tripping Swift 6's capture rules.
private final class TimeoutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Duration?
    var value: Duration? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Swift.Error?
    var value: Swift.Error? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
#endif
