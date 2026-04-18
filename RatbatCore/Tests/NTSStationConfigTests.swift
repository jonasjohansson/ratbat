#if os(macOS)
import XCTest
@testable import RatbatCore

/// Tests for the ``NTSStationConfig`` Codable surface, including the
/// backward-compat decode path from the pre-faceted on-disk shape.
/// Mirrors ``LastFMStationConfigTests`` — the NTS legacy shape was
/// simpler (only `tags` + `yearMin/yearMax`), so the test matrix is a
/// subset.
final class NTSStationConfigTests: XCTestCase {

    func testDefaults_areConservative() {
        let cfg = NTSStationConfig(name: "Test", query: FacetedQuery(genreTags: ["techno"]))
        XCTAssertEqual(cfg.query.tagMatch, .any)
        XCTAssertEqual(cfg.query.popularity, .middle)
        XCTAssertFalse(cfg.query.excludeOwnedLibrary)
        XCTAssertTrue(cfg.query.excludedArtists.isEmpty)
        XCTAssertTrue(cfg.shufflePool)
    }

    func testRoundTrip_preservesAllFields() throws {
        var cfg = NTSStationConfig(
            name: "T",
            query: FacetedQuery(genreTags: ["techno"]),
            shufflePool: false
        )
        cfg.query.yearMin = 1990
        cfg.query.yearMax = 1999
        cfg.query.regions = ["JP"]
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(NTSStationConfig.self, from: data)
        XCTAssertEqual(decoded, cfg)
        XCTAssertEqual(decoded.query.genreTags, ["techno"])
        XCTAssertEqual(decoded.query.yearMin, 1990)
        XCTAssertEqual(decoded.query.yearMax, 1999)
        XCTAssertEqual(decoded.query.regions, ["JP"])
        XCTAssertFalse(decoded.shufflePool)
    }

    /// Shape stored on disk before the faceted redesign. The decoder must
    /// hydrate a ``FacetedQuery`` from the flat `tags` / `yearMin` /
    /// `yearMax` fields without user action.
    func testDecode_preFacetedShape_hydratesFacetedQuery() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Legacy",
          "tags": ["techno"],
          "yearMin": 1990,
          "yearMax": 1999,
          "shufflePool": true
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NTSStationConfig.self, from: legacy)
        XCTAssertEqual(decoded.query.genreTags, ["techno"])
        XCTAssertEqual(decoded.query.yearMin, 1990)
        XCTAssertEqual(decoded.query.yearMax, 1999)
        XCTAssertTrue(decoded.shufflePool)
    }

    /// Legacy shapes with no year fields still decode, with yearMin /
    /// yearMax defaulting to nil on the hydrated query.
    func testDecode_preFacetedShape_withoutYearFields() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Ambient",
          "tags": ["ambient", "drone"],
          "shufflePool": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NTSStationConfig.self, from: legacy)
        XCTAssertEqual(decoded.query.genreTags, ["ambient", "drone"])
        XCTAssertNil(decoded.query.yearMin)
        XCTAssertNil(decoded.query.yearMax)
        XCTAssertFalse(decoded.shufflePool)
    }

    /// Encoding must emit the new shape only — no legacy keys bleed
    /// through on write-back, matching how the Last.fm / Bandcamp configs
    /// settled the disk shape.
    func testEncode_writesNewShapeOnly() throws {
        let cfg = NTSStationConfig(name: "T", query: FacetedQuery(genreTags: ["techno"]))
        let data = try JSONEncoder().encode(cfg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["query"], "new shape should include a query field")
        XCTAssertNil(json["tags"], "legacy 'tags' key should not be written")
        XCTAssertNil(json["yearMin"], "legacy top-level 'yearMin' should not be written")
        XCTAssertNil(json["yearMax"], "legacy top-level 'yearMax' should not be written")
    }
}
#endif
