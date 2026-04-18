#if os(macOS)
import XCTest
@testable import RatbatCore

final class MusicBrainzClientTests: XCTestCase {

    func testParseRecordingSearch_extractsFirstReleaseYear() throws {
        let data = try fixtureData("musicbrainz-recording-search")
        let year = MusicBrainzClient.parseFirstReleaseYear(from: data)
        XCTAssertEqual(year, 2003)
    }

    func testParseArtistSearch_extractsISOCountryCode() throws {
        let data = try fixtureData("musicbrainz-artist-search")
        let code = MusicBrainzClient.parseCountryCode(from: data)
        XCTAssertEqual(code, "BR")
    }

    func testParseRecordingSearch_emptyResults_returnsNil() {
        let empty = Data("""
        { "created": "2026-04-18T00:00:00.000Z", "count": 0, "recordings": [] }
        """.utf8)
        XCTAssertNil(MusicBrainzClient.parseFirstReleaseYear(from: empty))
    }

    func testParseArtistSearch_noArea_returnsNil() {
        let noArea = Data("""
        { "count": 1, "artists": [{ "id": "x", "name": "X" }] }
        """.utf8)
        XCTAssertNil(MusicBrainzClient.parseCountryCode(from: noArea))
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        // `project.yml` ships `Tests/Fixtures` as a `type: folder` resource,
        // so the fixture ends up nested under `Fixtures/` inside the bundle.
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        throw XCTSkip("Fixture \(name).json not found in test bundle")
    }
}
#endif
