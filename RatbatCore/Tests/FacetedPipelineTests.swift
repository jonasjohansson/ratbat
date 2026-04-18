#if os(macOS)
import XCTest
@testable import RatbatCore

final class FacetedPipelineTests: XCTestCase {

    // MARK: - Tag mode

    func testApplyTagMode_any_unions() {
        let candidates: [(SourceCandidate, Set<String>)] = [
            (candidate(artist: "A", title: "a"), ["techno"]),
            (candidate(artist: "B", title: "b"), ["house"]),
            (candidate(artist: "C", title: "c"), ["techno", "house"]),
        ]
        let query: Set<String> = ["techno", "house"]
        let result = FacetedPipeline.applyTagMode(candidates, required: query, mode: .any)
        XCTAssertEqual(result.count, 3) // all three survive
    }

    func testApplyTagMode_all_intersects() {
        let candidates: [(SourceCandidate, Set<String>)] = [
            (candidate(artist: "A", title: "a"), ["techno"]),
            (candidate(artist: "B", title: "b"), ["house"]),
            (candidate(artist: "C", title: "c"), ["techno", "house"]),
        ]
        let query: Set<String> = ["techno", "house"]
        let result = FacetedPipeline.applyTagMode(candidates, required: query, mode: .all)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.artist, "C")
    }

    // MARK: - Exclusions

    func testApplyExclusions_dropsExcludedArtists() async {
        let cands = [
            candidate(artist: "Keep", title: "k"),
            candidate(artist: "Drop", title: "d"),
        ]
        let out = await FacetedPipeline.applyExclusions(
            cands,
            excludedArtists: ["drop"],
            excludeOwnedLibrary: false,
            tasteProfile: nil
        )
        XCTAssertEqual(out.map(\.artist), ["Keep"])
    }

    // MARK: - Helper

    private func candidate(artist: String, title: String, resolved: URL? = nil) -> SourceCandidate {
        SourceCandidate(
            artist: artist,
            title: title,
            resolvedURL: resolved,
            listenersHint: nil,
            matchedTags: []
        )
    }
}
#endif
