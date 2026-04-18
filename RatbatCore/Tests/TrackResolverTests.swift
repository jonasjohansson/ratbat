#if os(macOS)
import XCTest
@testable import RatbatCore

/// Scaffolding tests for ``TrackResolver``.
///
/// We don't actually hit YouTube here — the happy path needs network,
/// a real venv, and ffmpeg. These tests exercise the service plumbing:
/// init creates the cache dir, cache size/listing primitives reflect
/// the filesystem, and `prune` removes files.
final class TrackResolverTests: XCTestCase {

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
    ///
    /// We can't hit real yt-dlp in a unit test, so this uses a shell-script
    /// stand-in for the venv Python: it records the arg list, writes a
    /// one-byte fake output file at the requested `--output` path, and
    /// emits a JSON success payload on stdout. That exercises the branch
    /// without touching the network.
    func testResolveWithCandidateInvokesDirectURLPath() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // Stub "python" — a tiny bash script. It expects the wrapper path
        // at $1, records the rest of argv for assertion, writes a fake
        // m4a at the --output path, and prints the wrapper's JSON shape.
        let stub = tempRoot.appendingPathComponent("fake-python.sh")
        let argLog = tempRoot.appendingPathComponent("args.txt")
        let script = """
        #!/bin/bash
        # Skip $1 (the wrapper script path) — mirror how the venv python
        # actually invokes the script as its first arg.
        shift
        # Dump the rest of argv, one per line, for the Swift side to read.
        printf '%s\\n' "$@" > "\(argLog.path)"
        # Find --output <PATH> and create a byte there to satisfy the
        # "file actually landed" post-condition.
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --output) out="$2"; shift 2;;
            *) shift;;
          esac
        done
        if [ -n "$out" ]; then
          printf 'x' > "$out"
        fi
        # Emit the wrapper's JSON success payload.
        printf '{"youtube_id": "bandcamp:stub-id", "matched_title": "Stub Title"}'
        exit 0
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        // Wrapper script file just needs to exist — the stub ignores its
        // contents.
        let wrapper = tempRoot.appendingPathComponent("resolve_track.py")
        try Data().write(to: wrapper)

        let cacheRoot = tempRoot.appendingPathComponent("cache", isDirectory: true)
        let resolver = try TrackResolver(
            venvPython: stub,
            wrapperScript: wrapper,
            cacheRoot: cacheRoot
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

        // Verify the arg list contained `--source-url <bandcampURL>` —
        // i.e. the direct-URL branch was taken, not the search path.
        let logged = try String(contentsOf: argLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertTrue(logged.contains("--source-url"), "argv missing --source-url: \(logged)")
        XCTAssertTrue(logged.contains(bandcampURL.absoluteString), "argv missing Bandcamp URL: \(logged)")

        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Candidate without a ``resolvedURL`` should route through the
    /// existing search path — no `--source-url` argument on the wrapper.
    func testResolveWithCandidateFallsBackToSearchPath() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let stub = tempRoot.appendingPathComponent("fake-python.sh")
        let argLog = tempRoot.appendingPathComponent("args.txt")
        let script = """
        #!/bin/bash
        shift
        printf '%s\\n' "$@" > "\(argLog.path)"
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --output) out="$2"; shift 2;;
            *) shift;;
          esac
        done
        if [ -n "$out" ]; then
          printf 'x' > "$out"
        fi
        printf '{"youtube_id": "ytid123", "matched_title": "Match"}'
        exit 0
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let wrapper = tempRoot.appendingPathComponent("resolve_track.py")
        try Data().write(to: wrapper)

        let resolver = try TrackResolver(
            venvPython: stub,
            wrapperScript: wrapper,
            cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true)
        )

        let candidate = SourceCandidate(artist: "A", title: "B") // no resolvedURL
        let resolution = try await resolver.resolve(candidate: candidate)

        XCTAssertEqual(resolution.youtubeID, "ytid123")

        let logged = try String(contentsOf: argLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertFalse(logged.contains("--source-url"), "search path must not pass --source-url: \(logged)")

        try? FileManager.default.removeItem(at: tempRoot)
    }
}
#endif
