import XCTest
@testable import RatbatCore

final class SelectionPolicyTests: XCTestCase {

    // MARK: - Policy value

    func testDefaultsAreTheShippedDefaults() {
        let p = SelectionPolicy.default
        XCTAssertEqual(p.newMusicShare, 0.7, accuracy: 0.0001)
        XCTAssertFalse(p.excludeMixSets, "the toggle ships off — it removes music")
        XCTAssertEqual(p.mixSetMinimumDuration, 1200)
    }

    func testShareIsClampedAtTheBoundary() {
        XCTAssertEqual(SelectionPolicy(newMusicShare: 4.2).newMusicShare, 1.0)
        XCTAssertEqual(SelectionPolicy(newMusicShare: -1).newMusicShare, 0.0)
    }

    func testArtistKeyIsTrimmedAndCaseFolded() {
        XCTAssertEqual(SelectionOrdering.artistKey("  Aphex Twin "), "aphex twin")
        XCTAssertEqual(SelectionOrdering.artistKey("APHEX TWIN"), "aphex twin")
    }

    // MARK: - Ordering invariants
    //
    // The dial REORDERS and never REMOVES. That is the whole reason it cannot
    // starve a station, and it is why these two invariants are asserted on
    // every case below rather than in one token test.

    private func order(
        _ items: [String], share: Double, owned: Set<String>,
        phase: (new: Int, total: Int) = (0, 0)
    ) -> NewnessOrdering<String> {
        SelectionOrdering.orderByNewness(items, share: share, phase: phase) {
            !owned.contains($0)
        }
    }

    private func assertPermutation(
        _ result: [String], _ input: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.count, input.count, "count must be preserved", file: file, line: line)
        XCTAssertEqual(result.sorted(), input.sorted(), "must be a permutation", file: file, line: line)
    }

    func testOrderingNeverAddsOrDropsCandidates() {
        let items = ["n1", "o1", "n2", "o2", "n3"]
        let owned: Set<String> = ["o1", "o2"]
        for share in [0.0, 0.25, 0.5, 0.7, 1.0] {
            let r = order(items, share: share, owned: owned)
            assertPermutation(r.ordered, items)
        }
    }

    func testFullyNewDialLeadsWithNewButStillKeepsOwned() {
        let items = ["n1", "o1", "n2", "o2"]
        let r = order(items, share: 1.0, owned: ["o1", "o2"])
        XCTAssertEqual(Array(r.ordered.prefix(2)), ["n1", "n2"])
        // The owned tracks are appended, not discarded: at 100% the station
        // runs out of new music rather than running out of music.
        assertPermutation(r.ordered, items)
    }

    func testFullyOwnedDialLeadsWithOwnedButStillKeepsNew() {
        let items = ["n1", "o1", "n2", "o2"]
        let r = order(items, share: 0.0, owned: ["o1", "o2"])
        XCTAssertEqual(Array(r.ordered.prefix(2)), ["o1", "o2"])
        assertPermutation(r.ordered, items)
    }

    /// The point of a deterministic quota rather than a coin flip: at 0.7 the
    /// listener cannot get a long run of owned tracks by bad luck.
    func testEveryPrefixTracksTheRequestedShare() {
        let items = (0..<40).map { $0 % 2 == 0 ? "n\($0)" : "o\($0)" }
        let owned = Set(items.filter { $0.hasPrefix("o") })
        let share = 0.7
        let r = order(items, share: share, owned: owned)

        var newSoFar = 0
        for (i, item) in r.ordered.enumerated() {
            if !owned.contains(item) { newSoFar += 1 }
            let k = Double(i + 1)
            // Only meaningful while both buckets still have supply; the tail
            // is necessarily single-bucket.
            if i < 20 {
                XCTAssertLessThan(
                    abs(Double(newSoFar) - share * k), 1.0,
                    "prefix \(i + 1) drifted from the requested share"
                )
            }
        }
    }

    func testRankOrderIsPreservedWithinEachBucket() {
        let items = ["n1", "n2", "n3", "o1", "o2", "o3"]
        let r = order(items, share: 0.5, owned: ["o1", "o2", "o3"])
        XCTAssertEqual(r.ordered.filter { $0.hasPrefix("n") }, ["n1", "n2", "n3"])
        XCTAssertEqual(r.ordered.filter { $0.hasPrefix("o") }, ["o1", "o2", "o3"])
    }

    func testSupplyCountsAreReported() {
        let r = order(["n1", "n2", "o1"], share: 0.7, owned: ["o1"])
        XCTAssertEqual(r.newSupply, 2)
        XCTAssertEqual(r.ownedSupply, 1)
    }

    /// When the preferred bucket is empty the dial cannot be honoured. It must
    /// still hand back every candidate — and say so, so the shortfall reaches
    /// the audit log instead of silently reading as "the dial does nothing".
    func testShortfallIsReportedWhenNewSupplyIsExhausted() {
        let items = ["o1", "o2", "o3"]
        let r = order(items, share: 1.0, owned: ["o1", "o2", "o3"])
        assertPermutation(r.ordered, items)
        XCTAssertEqual(r.newSupply, 0)
        XCTAssertGreaterThan(r.shortfall, 0, "a 100% dial over an all-owned pool is a shortfall")
    }

    func testNoShortfallWhenBothBucketsCanSatisfyTheDial() {
        let items = (0..<20).map { $0 % 2 == 0 ? "n\($0)" : "o\($0)" }
        let r = order(items, share: 0.5, owned: Set(items.filter { $0.hasPrefix("o") }))
        XCTAssertEqual(r.shortfall, 0)
    }

    /// Phase carry is what makes the dial a ratio over *plays* rather than over
    /// pool slots: candidates rejected after ordering (already played, resolve
    /// failed) would otherwise skew the realised ratio with no correction.
    func testPhaseCarryCorrectsAPriorDeficit() {
        let items = ["n1", "o1", "n2", "o2"]
        let owned: Set<String> = ["o1", "o2"]
        // 10 plays so far, none of them new, against a 0.7 dial: deep deficit.
        let r = order(items, share: 0.7, owned: owned, phase: (new: 0, total: 10))
        XCTAssertEqual(r.ordered.first, "n1", "a deficit must be repaid first")
    }

    func testPhaseCarryBacksOffWhenAlreadyAhead() {
        let items = ["n1", "o1", "n2", "o2"]
        let owned: Set<String> = ["o1", "o2"]
        // 10 plays, all new, against a 0.3 dial: well ahead, so owned is due.
        let r = order(items, share: 0.3, owned: owned, phase: (new: 10, total: 10))
        XCTAssertEqual(r.ordered.first, "o1")
    }

    func testEmptyPoolIsHandled() {
        let r = order([], share: 0.7, owned: [])
        XCTAssertTrue(r.ordered.isEmpty)
        XCTAssertEqual(r.shortfall, 0)
    }

    func testSingleBucketPoolIsUntouched() {
        let items = ["n1", "n2", "n3"]
        let r = order(items, share: 0.7, owned: [])
        XCTAssertEqual(r.ordered, items)
    }
}
