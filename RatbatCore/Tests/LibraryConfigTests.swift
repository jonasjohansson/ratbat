import XCTest
@testable import RatbatCore

final class LibraryConfigTests: XCTestCase {
    private let suiteName = "se.jonasjohansson.ratbat.tests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testMusicFolderPersistsAcrossInstances() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratbat-library")
        let defaults = UserDefaults(suiteName: suiteName)!

        let config = LibraryConfig(defaults: defaults)
        XCTAssertNil(config.musicFolder)

        config.musicFolder = tempURL
        XCTAssertEqual(config.musicFolder?.path, tempURL.path)

        let reloaded = LibraryConfig(defaults: defaults)
        XCTAssertEqual(reloaded.musicFolder?.path, tempURL.path)
    }

    func testMusicFolderCanBeCleared() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        let config = LibraryConfig(defaults: defaults)
        config.musicFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("x")
        config.musicFolder = nil
        XCTAssertNil(config.musicFolder)
    }
}
