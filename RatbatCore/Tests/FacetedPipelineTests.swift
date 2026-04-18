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

    func testApplyTagMode_all_isCaseInsensitive() {
        let candidates: [(SourceCandidate, Set<String>)] = [
            (candidate(artist: "C", title: "c"), ["TECHNO", "House"]),
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

    func testApplyExclusions_dropsOwnedLibraryArtists() async {
        let profile = TasteProfile()
        await profile.ingestLibrary([
            Track(
                url: URL(fileURLWithPath: "/tmp/owned.m4a"),
                title: "t",
                artist: "Owned Artist",
                album: "",
                duration: 1
            )
        ])
        let cands = [
            candidate(artist: "Owned Artist", title: "a"),
            candidate(artist: "Fresh Artist", title: "b"),
        ]
        let out = await FacetedPipeline.applyExclusions(
            cands,
            excludedArtists: [],
            excludeOwnedLibrary: true,
            tasteProfile: profile
        )
        XCTAssertEqual(out.map(\.artist), ["Fresh Artist"])
    }

    // MARK: - Era filter

    func testApplyEraFilter_dropsOutOfRange_keepsUnknownWhenFailOpen() async {
        let stub = StubMB(years: [
            "keep — k": 1995,
            "drop — d": 2010,
            // "unknown — u" not mapped → returns nil
        ])
        let cands = [
            candidate(artist: "keep", title: "k"),
            candidate(artist: "drop", title: "d"),
            candidate(artist: "unknown", title: "u"),
        ]
        let out = await FacetedPipeline.applyEraFilter(
            cands,
            yearMin: 1990,
            yearMax: 1999,
            mb: stub
        )
        XCTAssertEqual(Set(out.map(\.artist)), ["keep", "unknown"])
    }

    func testApplyEraFilter_noRange_returnsAll() async {
        let stub = StubMB(years: [:])
        let cands = [candidate(artist: "a", title: "a")]
        let out = await FacetedPipeline.applyEraFilter(cands, yearMin: nil, yearMax: nil, mb: stub)
        XCTAssertEqual(out.count, 1)
    }

    // MARK: - Region filter

    func testApplyRegionFilter_keepsMatchAndUnknown() async {
        let stub = StubMB(countries: ["JP": ["Japanese Artist"], "BR": ["Brazilian Artist"]])
        let cands = [
            candidate(artist: "Japanese Artist", title: "a"),
            candidate(artist: "Brazilian Artist", title: "b"),
            candidate(artist: "Unknown Artist", title: "c"),
        ]
        let out = await FacetedPipeline.applyRegionFilter(cands, regions: ["JP"], mb: stub)
        XCTAssertEqual(Set(out.map(\.artist)), ["Japanese Artist", "Unknown Artist"])
    }

    // MARK: - Helper

    private func candidate(artist: String, title: String, resolvedURL: URL? = nil) -> SourceCandidate {
        SourceCandidate(
            artist: artist,
            title: title,
            resolvedURL: resolvedURL,
            listenersHint: nil,
            matchedTags: []
        )
    }
}

// Stub MB — local test double that implements the same public surface
// the pipeline consumes. Defined as a small protocol so the real
// MusicBrainzClient and this stub both satisfy it.
private actor StubMB: MusicBrainzLookup {
    private let yearMap: [String: Int]
    private let countryMap: [String: String]
    init(years: [String: Int] = [:], countries: [String: [String]] = [:]) {
        self.yearMap = years
        var flat: [String: String] = [:]
        for (code, artists) in countries {
            for a in artists {
                flat[a.lowercased()] = code
            }
        }
        self.countryMap = flat
    }
    func firstReleaseYear(artist: String, title: String) async -> Int? {
        yearMap["\(artist.lowercased()) — \(title.lowercased())"]
    }
    func countryCode(forArtist artist: String) async -> String? {
        countryMap[artist.lowercased()]
    }
}
#endif
