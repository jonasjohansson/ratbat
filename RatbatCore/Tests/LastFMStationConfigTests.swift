#if os(macOS)
import XCTest
@testable import RatbatCore

final class LastFMStationConfigTests: XCTestCase {

    func testDefaults_areConservative() {
        let cfg = LastFMStationConfig(name: "Test", tags: ["techno"])
        XCTAssertEqual(cfg.tagMode, .any)
        XCTAssertEqual(cfg.popularity, .middle)
        XCTAssertEqual(cfg.precision, .verified)
        XCTAssertFalse(cfg.excludeOwnedLibrary)
        XCTAssertTrue(cfg.excludedArtists.isEmpty)
    }

    func testRoundTrip_preservesAllFields() throws {
        var cfg = LastFMStationConfig(name: "T", tags: ["techno", "1990s"])
        cfg.tagMode = .all
        cfg.popularity = .deepCuts
        cfg.precision = .strict
        cfg.excludeOwnedLibrary = true
        cfg.excludedArtists = ["Groove Coverage", "Scooter"]
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(LastFMStationConfig.self, from: data)
        XCTAssertEqual(decoded.tagMode, .all)
        XCTAssertEqual(decoded.popularity, .deepCuts)
        XCTAssertEqual(decoded.precision, .strict)
        XCTAssertTrue(decoded.excludeOwnedLibrary)
        XCTAssertEqual(decoded.excludedArtists, ["Groove Coverage", "Scooter"])
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
        XCTAssertEqual(decoded.tagMode, .any)
        XCTAssertEqual(decoded.popularity, .middle)
        XCTAssertEqual(decoded.precision, .verified)
        XCTAssertFalse(decoded.excludeOwnedLibrary)
        XCTAssertTrue(decoded.excludedArtists.isEmpty)
    }
}
#endif
