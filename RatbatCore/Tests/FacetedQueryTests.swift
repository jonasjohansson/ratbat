#if os(macOS)
import XCTest
@testable import RatbatCore

final class FacetedQueryTests: XCTestCase {

    func testDefaults_areSensible() {
        let q = FacetedQuery(genreTags: ["techno"])
        XCTAssertEqual(q.tagMatch, .any)
        XCTAssertEqual(q.popularity, .middle)
        XCTAssertNil(q.yearMin)
        XCTAssertNil(q.yearMax)
        XCTAssertTrue(q.regions.isEmpty)
        XCTAssertFalse(q.excludeOwnedLibrary)
        XCTAssertTrue(q.excludedArtists.isEmpty)
    }

    func testRoundTrip_preservesAllFields() throws {
        var q = FacetedQuery(genreTags: ["techno", "house"])
        q.yearMin = 1990
        q.yearMax = 1999
        q.regions = ["JP", "DE"]
        q.tagMatch = .all
        q.popularity = .deepCuts
        q.excludeOwnedLibrary = true
        q.excludedArtists = ["Excluded Artist"]
        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(FacetedQuery.self, from: data)
        XCTAssertEqual(decoded, q)
    }

    // MARK: suggestedName

    func testSuggestedName_singleTag() {
        XCTAssertEqual(FacetedQuery(genreTags: ["techno"]).suggestedName, "Techno")
    }

    func testSuggestedName_multipleTags() {
        XCTAssertEqual(
            FacetedQuery(genreTags: ["techno", "house"]).suggestedName,
            "Techno · House"
        )
    }

    func testSuggestedName_manyTagsTruncates() {
        let q = FacetedQuery(genreTags: ["techno", "house", "ambient", "jazz"])
        XCTAssertEqual(q.suggestedName, "Techno · House · Ambient · +1 more")
    }

    func testSuggestedName_compactDecadeEra() {
        var q = FacetedQuery(genreTags: ["techno"])
        q.yearMin = 1990
        q.yearMax = 1999
        XCTAssertEqual(q.suggestedName, "Techno (1990s)")
    }

    func testSuggestedName_openEndedEra() {
        var q = FacetedQuery(genreTags: ["techno"])
        q.yearMin = 2020
        XCTAssertEqual(q.suggestedName, "Techno (from 2020)")
    }

    func testSuggestedName_mixedEra() {
        var q = FacetedQuery(genreTags: ["techno"])
        q.yearMin = 1990
        q.yearMax = 2005
        XCTAssertEqual(q.suggestedName, "Techno (1990–2005)")
    }

    func testSuggestedName_singleRegion() {
        var q = FacetedQuery(genreTags: ["techno"])
        q.regions = ["JP"]
        XCTAssertEqual(q.suggestedName, "Japanese Techno")
    }

    func testSuggestedName_multipleRegions() {
        var q = FacetedQuery(genreTags: ["techno"])
        q.regions = ["JP", "DE"]
        XCTAssertEqual(q.suggestedName, "Techno (JP · DE)")
    }

    func testSuggestedName_combined() {
        var q = FacetedQuery(genreTags: ["techno"])
        q.yearMin = 1990
        q.yearMax = 1999
        q.regions = ["JP"]
        XCTAssertEqual(q.suggestedName, "Japanese Techno (1990s)")
    }

    func testSuggestedName_emptyFallback() {
        XCTAssertEqual(FacetedQuery(genreTags: []).suggestedName, "New Station")
    }

    func testSuggestedName_acronymPreserved() {
        XCTAssertEqual(FacetedQuery(genreTags: ["idm"]).suggestedName, "IDM")
    }
}
#endif
