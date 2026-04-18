#if os(macOS)
import XCTest
@testable import RatbatCore

/// Covers ``BandcampStationConfig`` value semantics — Codable round-trip
/// preserves every field, and the `sort` default matches the Bandcamp
/// endpoint's "s=new" tail-of-feed behaviour.
final class BandcampStationConfigTests: XCTestCase {

    func testRoundTrip_preservesAllFields() throws {
        let cfg = BandcampStationConfig(
            name: "Dungeon Synth",
            query: FacetedQuery(genreTags: ["dungeon synth"], yearMin: 2020),
            sort: .date
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(BandcampStationConfig.self, from: data)
        XCTAssertEqual(decoded.name, "Dungeon Synth")
        XCTAssertEqual(decoded.query.genreTags, ["dungeon synth"])
        XCTAssertEqual(decoded.query.yearMin, 2020)
        XCTAssertEqual(decoded.sort, .date)
    }

    func testDefaults_sortIsDate() {
        let cfg = BandcampStationConfig(name: "T", query: FacetedQuery(genreTags: ["techno"]))
        XCTAssertEqual(cfg.sort, .date)
    }
}
#endif
