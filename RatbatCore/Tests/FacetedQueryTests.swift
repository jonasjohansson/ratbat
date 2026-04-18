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
}
#endif
