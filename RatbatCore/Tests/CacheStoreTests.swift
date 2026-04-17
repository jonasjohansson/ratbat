import XCTest
@testable import RatbatCore

/// Tests for the on-disk scan cache. These don't need the library fixture —
/// they construct small synthetic playlists and round-trip them through
/// JSON on a temporary directory. Keeping them isolated from the AV stack
/// means they run in milliseconds regardless of the fixture's state.
final class CacheStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratbat-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root = tempRoot {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testSaveAndLoadRoundTrip() throws {
        // A nested playlist shape with a child folder exercises the
        // recursive-Codable path — if `Playlist.children` ever stopped
        // encoding correctly, this would catch it.
        let track = Track(
            url: URL(fileURLWithPath: "/fake/track.m4a"),
            title: "Song Title",
            artist: "Artist",
            album: "Album",
            duration: 180,
            trackNumber: 3,
            year: 2024,
            genre: "Ambient",
            bitrate: 256,
            fileSize: 12_345,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let child = Playlist(
            name: "Album",
            folder: URL(fileURLWithPath: "/fake/Album"),
            tracks: [track],
            children: [],
            kind: .folder
        )
        let parent = Playlist(
            name: "Artist",
            folder: URL(fileURLWithPath: "/fake"),
            tracks: [track],
            children: [child],
            kind: .folder
        )

        try CacheStore.save([parent], for: tempRoot)

        // The cache file should physically exist as a hidden dotfile in
        // the root, matching the path the indexer will look at on next launch.
        let expected = tempRoot.appendingPathComponent(".ratbat-cache.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))

        let loaded = try CacheStore.load(for: tempRoot)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Artist")
        XCTAssertEqual(loaded[0].tracks.count, 1)
        XCTAssertEqual(loaded[0].tracks[0].title, "Song Title")
        XCTAssertEqual(loaded[0].tracks[0].trackNumber, 3)
        XCTAssertEqual(loaded[0].children.count, 1)
        XCTAssertEqual(loaded[0].children[0].name, "Album")
    }

    func testLoadFailsWhenNoCache() {
        // A fresh temp directory has no cache — `load` must throw so
        // the view model falls through to a full scan.
        XCTAssertThrowsError(try CacheStore.load(for: tempRoot))
    }

    func testDeleteRemovesCache() throws {
        let playlist = Playlist(name: "X", folder: nil, tracks: [], children: [], kind: .folder)
        try CacheStore.save([playlist], for: tempRoot)
        XCTAssertNoThrow(try CacheStore.load(for: tempRoot))
        try CacheStore.delete(for: tempRoot)
        XCTAssertThrowsError(try CacheStore.load(for: tempRoot))
    }

    func testDeleteIsNoopWhenCacheMissing() throws {
        // Calling `delete` when nothing exists shouldn't throw — it's
        // fire-and-forget cleanup for the "force rescan" path.
        XCTAssertNoThrow(try CacheStore.delete(for: tempRoot))
    }

    func testLoadFailsOnVersionMismatch() throws {
        // Hand-write a JSON file with a version the current build doesn't
        // understand. This simulates an older cache surviving across a
        // schema bump — we want `load` to throw cleanly so the caller
        // treats it as "no cache" and rescans.
        let url = tempRoot.appendingPathComponent(".ratbat-cache.json")
        let garbage = """
        {"version": 999, "playlists": []}
        """.data(using: .utf8)!
        try garbage.write(to: url)

        XCTAssertThrowsError(try CacheStore.load(for: tempRoot)) { error in
            guard let cacheError = error as? CacheStore.CacheError else {
                XCTFail("Expected CacheStore.CacheError, got \(error)")
                return
            }
            XCTAssertEqual(cacheError, .versionMismatch)
        }
    }

    func testLoadFailsOnCorruptData() throws {
        // Truncated/garbage JSON: another real-world failure mode (a
        // crash mid-write pre-`.atomic` is now impossible, but an
        // external process might still corrupt the file).
        let url = tempRoot.appendingPathComponent(".ratbat-cache.json")
        try Data("not valid json".utf8).write(to: url)
        XCTAssertThrowsError(try CacheStore.load(for: tempRoot))
    }
}

// Minimal Equatable conformance for the thrown-error comparison above.
// Not exposed publicly because only the test cares.
extension CacheStore.CacheError: Equatable {
    public static func == (lhs: CacheStore.CacheError, rhs: CacheStore.CacheError) -> Bool {
        switch (lhs, rhs) {
        case (.versionMismatch, .versionMismatch): return true
        }
    }
}
