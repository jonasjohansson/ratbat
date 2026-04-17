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
}
#endif
