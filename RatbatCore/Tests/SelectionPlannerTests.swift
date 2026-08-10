import XCTest
@testable import RatbatCore

/// Tests for ``SelectionPlanner`` — the pure, platform-neutral step that
/// every source runs over its candidate pool.
///
/// Deliberately NOT wrapped in `#if os(macOS)`: the planner is the piece
/// ``PlaylistSource`` calls, and `PlaylistSource` compiles for iOS. If the
/// planner ever grows a dependency on a macOS-only type this file stops
/// building, which is the point.
final class SelectionPlannerTests: XCTestCase {

    private struct Candidate: Sendable, Hashable {
        var artist: String
        var title: String
        var duration: TimeInterval?
    }

    private func subject(_ c: Candidate) -> SelectionSubject {
        SelectionSubject(
            artist: c.artist,
            title: c.title,
            durationSeconds: c.duration,
            durationSource: c.duration == nil ? nil : "library",
            sourceURL: nil
        )
    }

    // MARK: - Classification runs always; enforcement is conditional

    func testToggleOff_classifiesAndShadowRecordsButRemovesNothing() {
        let pool = [
            Candidate(artist: "A", title: "Short One", duration: 200),
            Candidate(artist: "B", title: "Long One", duration: 2000),
        ]
        let result = SelectionPlanner.filterMixSets(
            pool,
            policy: SelectionPolicy(excludeMixSets: false),
            sourceKind: "playlist",
            subject: subject
        )

        XCTAssertEqual(result.kept.count, 2, "toggle off must remove nothing")
        XCTAssertEqual(result.exclusions.count, 1, "only the candidate that CLASSIFIES is logged")
        let row = try! XCTUnwrap(result.exclusions.first)
        XCTAssertEqual(row.title, "Long One")
        XCTAssertEqual(row.arm, SelectionArm.duration)
        XCTAssertFalse(row.enforced, "shadow record: nothing was actually dropped")
        XCTAssertEqual(row.durationSeconds, 2000)
        XCTAssertEqual(row.durationSource, "library")
    }

    func testToggleOn_removesClassifiedAndRecordsEnforced() {
        let pool = [
            Candidate(artist: "A", title: "Short One", duration: 200),
            Candidate(artist: "B", title: "Long One", duration: 2000),
        ]
        let result = SelectionPlanner.filterMixSets(
            pool,
            policy: SelectionPolicy(excludeMixSets: true),
            sourceKind: "playlist",
            subject: subject
        )

        XCTAssertEqual(result.kept.map(\.title), ["Short One"])
        XCTAssertEqual(result.exclusions.count, 1)
        XCTAssertTrue(result.exclusions[0].enforced)
        XCTAssertFalse(result.stoodDown)
    }

    func testUnclassifiedPoolLogsNothing() {
        let pool = [
            Candidate(artist: "A", title: "Track One", duration: 200),
            Candidate(artist: "B", title: "Track Two", duration: 300),
        ]
        let result = SelectionPlanner.filterMixSets(
            pool,
            policy: SelectionPolicy(excludeMixSets: true),
            sourceKind: "playlist",
            subject: subject
        )
        XCTAssertEqual(result.kept.count, 2)
        XCTAssertTrue(result.exclusions.isEmpty, "the whole pool must not be logged — only classified candidates")
    }

    // MARK: - Nil duration → title arm only

    func testNilDurationCannotFireTheDurationArm() {
        // The NTS / Last.fm shape: no duration reaches selection at all.
        let pool = [
            Candidate(artist: "A", title: "Some Track", duration: nil),
            Candidate(artist: "B", title: "Boiler Room 2019", duration: nil),
        ]
        let result = SelectionPlanner.filterMixSets(
            pool,
            policy: SelectionPolicy(excludeMixSets: true),
            sourceKind: "nts",
            subject: subject
        )
        XCTAssertEqual(result.kept.map(\.title), ["Some Track"])
        XCTAssertEqual(result.exclusions.count, 1)
        XCTAssertEqual(result.exclusions[0].arm, SelectionArm.title, "a nil duration must yield a title-arm-only outcome")
        XCTAssertNil(result.exclusions[0].durationSeconds)
        XCTAssertNil(result.exclusions[0].durationSource)
        XCTAssertEqual(result.exclusions[0].matchedText, "Boiler Room")
    }

    // MARK: - Starvation guard

    func testStarvationGuard_standsDownRatherThanEmptyingThePool() {
        let pool = [
            Candidate(artist: "A", title: "Boiler Room 2019", duration: nil),
            Candidate(artist: "B", title: "Long One", duration: 2000),
        ]
        let result = SelectionPlanner.filterMixSets(
            pool,
            policy: SelectionPolicy(excludeMixSets: true),
            sourceKind: "nts",
            subject: subject
        )

        XCTAssertEqual(result.kept.count, 2, "an empty pool is worse than a mix set — keep every candidate")
        XCTAssertTrue(result.stoodDown)
        XCTAssertTrue(
            result.exclusions.allSatisfy { !$0.enforced },
            "standing down means nothing was dropped, so no row may claim it was"
        )

        let guardRow = result.exclusions.first { $0.arm == SelectionArm.starvationGuard }
        let unwrapped = try! XCTUnwrap(guardRow, "a station-level row must explain the stand-down")
        XCTAssertEqual(unwrapped.artist, "")
        XCTAssertEqual(unwrapped.title, "")
        // matchedText is a column `exclusions(stationID:limit:)` actually
        // returns. A `note` column would not be reachable by any reader.
        let explanation = try! XCTUnwrap(unwrapped.matchedText)
        XCTAssertTrue(explanation.contains("2"), "the explanation must carry the numbers: \(explanation)")
        XCTAssertFalse(explanation.isEmpty)
    }

    // MARK: - The dial

    func testPlanOrdersByNewnessAndNeverRemoves() {
        let pool = [
            Candidate(artist: "Owned1", title: "t1", duration: nil),
            Candidate(artist: "Owned2", title: "t2", duration: nil),
            Candidate(artist: "New1", title: "t3", duration: nil),
            Candidate(artist: "New2", title: "t4", duration: nil),
        ]
        let plan = SelectionPlanner.plan(
            pool,
            policy: SelectionPolicy(newMusicShare: 1.0),
            phase: (0, 0),
            sourceKind: "bandcamp",
            ownedArtistKeys: ["owned1", "owned2"],
            subject: subject
        )
        XCTAssertEqual(plan.ordered.count, 4, "the dial reorders and never removes")
        XCTAssertEqual(Set(plan.ordered), Set(pool), "output must be a permutation of the input")
        XCTAssertEqual(plan.ordered.prefix(2).map(\.artist), ["New1", "New2"], "share 1.0 leads with new music")
    }

    func testShortfallIsRecordedSoAFullDialHasAnAnswerOnDisk() {
        let pool = [
            Candidate(artist: "Owned1", title: "t1", duration: nil),
            Candidate(artist: "Owned2", title: "t2", duration: nil),
        ]
        let plan = SelectionPlanner.plan(
            pool,
            policy: SelectionPolicy(newMusicShare: 1.0),
            phase: (0, 0),
            sourceKind: "bandcamp",
            ownedArtistKeys: ["owned1", "owned2"],
            subject: subject
        )
        XCTAssertEqual(plan.ordered.count, 2)
        XCTAssertEqual(plan.shortfall, 2, "asked for all-new over a pool with none")

        let row = plan.exclusions.first { $0.arm == SelectionArm.shortfall }
        let unwrapped = try! XCTUnwrap(row, "\"my 100% dial does nothing\" must have an answer on disk")
        XCTAssertFalse(unwrapped.enforced, "a shortfall drops nothing")
        let explanation = try! XCTUnwrap(unwrapped.matchedText)
        XCTAssertTrue(explanation.contains("2"), "explanation must carry the numbers: \(explanation)")
    }

    func testNoShortfallRowWhenTheDialIsSatisfied() {
        let pool = [
            Candidate(artist: "Owned1", title: "t1", duration: nil),
            Candidate(artist: "New1", title: "t2", duration: nil),
        ]
        let plan = SelectionPlanner.plan(
            pool,
            policy: SelectionPolicy(newMusicShare: 0.5),
            phase: (0, 0),
            sourceKind: "bandcamp",
            ownedArtistKeys: ["owned1"],
            subject: subject
        )
        XCTAssertEqual(plan.shortfall, 0)
        XCTAssertTrue(plan.exclusions.isEmpty)
    }

    func testPhaseCarryCorrectsDriftAcrossRefills() {
        // The station has played 3 tracks, all owned (candidates rejected
        // after ordering — already played, resolve failed). At share 0.5
        // the next refill must lead with new music to catch up.
        let pool = [
            Candidate(artist: "Owned1", title: "t1", duration: nil),
            Candidate(artist: "New1", title: "t2", duration: nil),
        ]
        let caughtUp = SelectionPlanner.plan(
            pool,
            policy: SelectionPolicy(newMusicShare: 0.5),
            phase: (new: 0, total: 3),
            sourceKind: "bandcamp",
            ownedArtistKeys: ["owned1"],
            subject: subject
        )
        XCTAssertEqual(caughtUp.ordered.first?.artist, "New1", "phase carry must self-correct the deficit")

        // The contrast: the same pool and the same dial, but the station is
        // AHEAD on new music. It must now lead with owned. If the phase were
        // ignored, both refills would order identically.
        let ahead = SelectionPlanner.plan(
            pool,
            policy: SelectionPolicy(newMusicShare: 0.5),
            phase: (new: 2, total: 2),
            sourceKind: "bandcamp",
            ownedArtistKeys: ["owned1"],
            subject: subject
        )
        XCTAssertEqual(ahead.ordered.first?.artist, "Owned1", "a surplus of new must be corrected the other way")
    }

    // MARK: - Mix set + dial compose

    func testPlanEnforcesMixSetsBeforeOrdering() {
        let pool = [
            Candidate(artist: "New1", title: "DJ Set at the Club", duration: nil),
            Candidate(artist: "New2", title: "Ordinary Track", duration: nil),
            Candidate(artist: "Owned1", title: "Another Track", duration: nil),
        ]
        let plan = SelectionPlanner.plan(
            pool,
            policy: SelectionPolicy(newMusicShare: 1.0, excludeMixSets: true),
            phase: (0, 0),
            sourceKind: "lastfm",
            ownedArtistKeys: ["owned1"],
            subject: subject
        )
        XCTAssertEqual(plan.ordered.count, 2)
        XCTAssertFalse(plan.ordered.contains { $0.title == "DJ Set at the Club" })
        XCTAssertTrue(plan.exclusions.contains { $0.arm == SelectionArm.title && $0.enforced })
    }
}
