import XCTest
@testable import JohanssoundCore

final class LibraryViewModelTests: XCTestCase {

    @MainActor
    func testLoadPopulatesTracksFromIndexer() async throws {
        let fixtures = try locateFixtureFolder()
        let vm = LibraryViewModel()
        XCTAssertTrue(vm.tracks.isEmpty)
        await vm.load(from: fixtures)
        XCTAssertFalse(vm.tracks.isEmpty)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
    }

    @MainActor
    func testLoadFinishesCleanlyOnMissingFolder() async throws {
        // The indexer treats a missing folder as "no files" (the enumerator
        // returns nil and `enumerateAudioFiles` yields an empty array), so we
        // don't assert on `error` — we only assert that the view model
        // finishes its load cycle without crashing and without stale state.
        let vm = LibraryViewModel()
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        await vm.load(from: bogus)
        XCTAssertFalse(vm.isLoading)
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
