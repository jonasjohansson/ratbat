import XCTest
@testable import JohanssoundCore

final class LibraryViewModelTests: XCTestCase {

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
