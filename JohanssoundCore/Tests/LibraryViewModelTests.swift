import XCTest
@testable import JohanssoundCore

final class LibraryViewModelTests: XCTestCase {

    /// Cached scans are now persisted to `{root}/.johanssound-cache.json`.
    /// Every ViewModel test that touches the fixture folder deletes that
    /// file first, so each test exercises a real scan rather than picking
    /// up a stale cache from an earlier run. (We also delete in tearDown
    /// to keep the bundle clean between runs.)
    private func clearFixtureCache() throws {
        let fixtures = try locateFixtureFolder()
        try? CacheStore.delete(for: fixtures)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try clearFixtureCache()
    }

    override func tearDownWithError() throws {
        try clearFixtureCache()
        try super.tearDownWithError()
    }

    @MainActor
    func testLoadPopulatesPlaylists() async throws {
        let fixtures = try locateFixtureFolder()
        let vm = LibraryViewModel()
        XCTAssertTrue(vm.playlists.isEmpty)
        await vm.load(from: fixtures)
        XCTAssertFalse(vm.playlists.isEmpty)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
        // Default selection should land on the first playlist (All Songs).
        XCTAssertNotNil(vm.selectedPlaylist)
        XCTAssertEqual(vm.selectedPlaylist?.kind, .allSongs)
    }

    @MainActor
    func testSelectingPlaylistUpdatesTracks() async throws {
        let fixtures = try locateFixtureFolder()
        let vm = LibraryViewModel()
        await vm.load(from: fixtures)
        guard let folderPL = vm.playlists.first(where: { $0.kind == .folder }) else {
            XCTFail("Expected at least one folder-kind playlist")
            return
        }
        vm.selectedPlaylistID = folderPL.id
        XCTAssertEqual(vm.tracks.count, folderPL.tracks.count)
        XCTAssertEqual(vm.selectedPlaylist?.id, folderPL.id)
    }

    @MainActor
    func testLoadFinishesCleanlyOnMissingFolder() async {
        // The indexer treats a missing folder as "no playlists" (the
        // directory read fails and we surface an empty result), so we don't
        // assert on `error` — we only assert that the view model finishes
        // its load cycle without crashing and without stale state.
        let vm = LibraryViewModel()
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        await vm.load(from: bogus)
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.playlists.isEmpty)
        XCTAssertNil(vm.selectedPlaylist)
        XCTAssertTrue(vm.tracks.isEmpty)
    }

    @MainActor
    func testSecondLoadHitsCache() async throws {
        // First load does a real scan and (best-effort) writes a cache.
        // If the bundle resources directory is read-only, the cache write
        // silently fails and we skip — the test is validating cache-path
        // behaviour, not disk permissions.
        let fixtures = try locateFixtureFolder()
        let vm1 = LibraryViewModel()
        await vm1.load(from: fixtures)
        XCTAssertFalse(vm1.playlists.isEmpty)

        let cachePath = fixtures.appendingPathComponent(".johanssound-cache.json")
        guard FileManager.default.fileExists(atPath: cachePath.path) else {
            throw XCTSkip("Fixture folder is read-only; cache write didn't take — skipping")
        }

        // Second load: different ViewModel, same folder. Should hit the
        // cache and return the same playlist names without invoking the
        // indexer. We can't easily assert "didn't scan" without dependency
        // injection, but we can verify the result is non-empty and the
        // playlist names match, which is enough to know the path wired up.
        let vm2 = LibraryViewModel()
        await vm2.load(from: fixtures)
        XCTAssertEqual(
            vm1.playlists.map(\.name),
            vm2.playlists.map(\.name)
        )
        XCTAssertNil(vm2.scanProgress, "Cache hit should leave scanProgress nil")
    }

    // MARK: - Helpers
    private func locateFixtureFolder() throws -> URL {
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: "library", withExtension: nil, subdirectory: "Fixtures") {
            return url
        }
        if let url = bundle.url(forResource: "library", withExtension: nil) {
            return url
        }
        if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("library")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let flatCandidate = resourceURL.appendingPathComponent("library")
            if FileManager.default.fileExists(atPath: flatCandidate.path) {
                return flatCandidate
            }
        }
        throw XCTSkip("Fixture folder not bundled — check project.yml test target resources")
    }
}
