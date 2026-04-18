#if os(macOS)
import XCTest
@testable import RatbatCore

final class LastFMStationConfigTests: XCTestCase {

    func testDefaults_areConservative() {
        let cfg = LastFMStationConfig(name: "Test", query: FacetedQuery(genreTags: ["techno"]))
        XCTAssertEqual(cfg.query.tagMatch, .any)
        XCTAssertEqual(cfg.query.popularity, .middle)
        XCTAssertFalse(cfg.query.excludeOwnedLibrary)
        XCTAssertTrue(cfg.query.excludedArtists.isEmpty)
    }

    func testRoundTrip_preservesAllFields() throws {
        var cfg = LastFMStationConfig(
            name: "T",
            query: FacetedQuery(genreTags: ["techno", "1990s"])
        )
        cfg.query.tagMatch = .all
        cfg.query.popularity = .deepCuts
        cfg.query.excludeOwnedLibrary = true
        cfg.query.excludedArtists = ["Groove Coverage", "Scooter"]
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(LastFMStationConfig.self, from: data)
        XCTAssertEqual(decoded.query.tagMatch, .all)
        XCTAssertEqual(decoded.query.popularity, .deepCuts)
        XCTAssertTrue(decoded.query.excludeOwnedLibrary)
        XCTAssertEqual(decoded.query.excludedArtists, ["Groove Coverage", "Scooter"])
    }

    func testDecode_legacyJSONWithoutNewFields_fillsDefaults() throws {
        // Shape stored on Jonas's Mac before the v2 config bump — missing
        // all the filter fields. The decoder must read it and supply the
        // documented defaults instead of throwing.
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Legacy",
          "tags": ["techno"],
          "shufflePool": true
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LastFMStationConfig.self, from: legacy)
        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertEqual(decoded.query.genreTags, ["techno"])
        XCTAssertEqual(decoded.query.tagMatch, .any)
        XCTAssertEqual(decoded.query.popularity, .middle)
        XCTAssertFalse(decoded.query.excludeOwnedLibrary)
        XCTAssertTrue(decoded.query.excludedArtists.isEmpty)
    }

    func testDecode_preFacetedShape_hydratesFacetedQuery() throws {
        // Shape as stored on disk before the faceted redesign. Every pre-
        // facet field is present; the decoder must promote them into the new
        // FacetedQuery-carrying shape without user action.
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Legacy",
          "tags": ["techno", "house"],
          "yearMin": 1990,
          "yearMax": 1999,
          "shufflePool": true,
          "tagMode": "all",
          "popularity": "deepCuts",
          "precision": "verified",
          "excludeOwnedLibrary": true,
          "excludedArtists": ["Scooter"]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LastFMStationConfig.self, from: legacy)
        XCTAssertEqual(decoded.query.genreTags, ["techno", "house"])
        XCTAssertEqual(decoded.query.yearMin, 1990)
        XCTAssertEqual(decoded.query.yearMax, 1999)
        XCTAssertEqual(decoded.query.tagMatch, .all)
        XCTAssertEqual(decoded.query.popularity, .deepCuts)
        XCTAssertTrue(decoded.query.excludeOwnedLibrary)
        XCTAssertEqual(decoded.query.excludedArtists, ["Scooter"])
    }

    func testEncode_writesNewShapeOnly() throws {
        var cfg = LastFMStationConfig(name: "T", query: FacetedQuery(genreTags: ["techno"]))
        cfg.query.yearMin = 1990
        let data = try JSONEncoder().encode(cfg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["query"], "new shape should include a query field")
        XCTAssertNil(json["tags"], "legacy 'tags' key should not be written")
        XCTAssertNil(json["yearMin"], "legacy top-level 'yearMin' should not be written")
    }
}
#endif
