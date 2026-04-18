#if os(macOS)
import XCTest
@testable import RatbatCore

final class BandcampClientTests: XCTestCase {

    func testParseDiscoverPage_extractsArtistTitleURL() throws {
        let data = try fixtureJSON("bandcamp-discover-techno")
        let (releases, totalCount) = BandcampClient.parseDiscoverPage(data: data)
        XCTAssertGreaterThan(releases.count, 0, "fixture must contain at least one release")
        XCTAssertGreaterThan(totalCount, 0)
        let first = releases[0]
        XCTAssertFalse(first.artist.isEmpty)
        XCTAssertFalse(first.title.isEmpty)
        XCTAssertEqual(first.releaseURL.scheme, "https")
        // URL must be either bandcamp.com subdomain or a custom domain
        XCTAssertTrue(
            first.releaseURL.host?.hasSuffix("bandcamp.com") == true
            || first.releaseURL.host != nil
        )
    }

    func testParseDiscoverPage_malformedJSON_returnsEmpty() {
        let garbage = Data("not json".utf8)
        let (releases, totalCount) = BandcampClient.parseDiscoverPage(data: garbage)
        XCTAssertEqual(releases.count, 0)
        XCTAssertEqual(totalCount, 0)
    }

    func testParseDiscoverPage_parsesReleaseDate() throws {
        let data = try fixtureJSON("bandcamp-discover-techno")
        let (releases, _) = BandcampClient.parseDiscoverPage(data: data)
        XCTAssertNotNil(releases.first?.releaseDate, "releaseDate should parse from RFC 1123 format")
        if let date = releases.first?.releaseDate {
            let year = Calendar(identifier: .gregorian).component(.year, from: date)
            XCTAssertGreaterThanOrEqual(year, 2020)
            XCTAssertLessThanOrEqual(year, 2030)
        }
    }

    func testParseDiscoverPage_trackItemUsesTrackPath() throws {
        let data = try fixtureJSON("bandcamp-discover-synthetic")
        let (releases, _) = BandcampClient.parseDiscoverPage(data: data)
        let track = releases.first { $0.title == "Track Title" }
        XCTAssertNotNil(track)
        XCTAssertEqual(track?.releaseURL.absoluteString, "https://artistname.bandcamp.com/track/track-slug")
    }

    func testParseDiscoverPage_customDomainPreferredOverSubdomain() throws {
        let data = try fixtureJSON("bandcamp-discover-synthetic")
        let (releases, _) = BandcampClient.parseDiscoverPage(data: data)
        let customDomain = releases.first { $0.title == "Custom Domain Album" }
        XCTAssertNotNil(customDomain)
        XCTAssertEqual(customDomain?.releaseURL.absoluteString, "https://records.example/album/custom-album")
    }

    // MARK: - Helpers

    private func fixtureJSON(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        guard let url else { throw XCTSkip("Fixture \(name).json missing") }
        return try Data(contentsOf: url)
    }
}
#endif
