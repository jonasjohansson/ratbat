import XCTest
@testable import RatbatCore

/// The reaper's output is fed straight to `kill`, so these tests are mostly
/// about what it must **refuse** to match.
///
/// Background: quitting Ratbat left its `cloudflared` child running,
/// reparented to launchd. Restarts accumulated replicas — one was found
/// still alive nearly eight hours after its parent died. A termination hook
/// handles ordinary exits; SIGKILL is uncatchable, so this handles the rest.
final class TunnelReaperTests: XCTestCase {

    private let ours = "/Applications/Ratbat.app/Contents/Resources/cloudflared"
    /// The real machine also runs this, serving an unrelated service from a
    /// different config — and it is itself PPID 1.
    private let somebodyElses = "/opt/homebrew/bin/cloudflared"

    private func p(_ pid: Int32, _ ppid: Int32, _ path: String) -> TunnelReaper.ProcessSnapshot {
        .init(pid: pid, parentPID: ppid, executablePath: path)
    }

    // MARK: - What it must match

    func testReapsOurBundledBinaryOnceReparented() {
        let found = TunnelReaper.orphans(
            among: [p(70797, 1, ours)],
            bundledBinary: ours,
            ownPID: 91973
        )
        XCTAssertEqual(found, [70797])
    }

    func testReapsSeveralOrphansFromRepeatedRestarts() {
        let found = TunnelReaper.orphans(
            among: [p(100, 1, ours), p(200, 1, ours), p(300, 1, ours)],
            bundledBinary: ours,
            ownPID: 999
        )
        XCTAssertEqual(found, [100, 200, 300])
    }

    // MARK: - What it must NOT match

    /// The one that would take a service off the air. A substring or
    /// "contains cloudflared" filter kills this; exact path equality cannot.
    func testNeverTouchesADifferentCloudflaredEvenThoughItIsAlsoPPID1() {
        let found = TunnelReaper.orphans(
            among: [p(38305, 1, somebodyElses)],
            bundledBinary: ours,
            ownPID: 91973
        )
        XCTAssertEqual(found, [], "an unrelated cloudflared at PPID 1 must be left alone")
    }

    /// Our own live child has our pid as its parent, never 1.
    func testNeverReapsTheCurrentInstancesOwnChild() {
        let found = TunnelReaper.orphans(
            among: [p(91980, 91973, ours)],
            bundledBinary: ours,
            ownPID: 91973
        )
        XCTAssertEqual(found, [], "the running instance's own tunnel must survive")
    }

    /// A second Ratbat running concurrently owns its child too.
    func testNeverReapsAnotherLiveInstancesChild() {
        let found = TunnelReaper.orphans(
            among: [p(500, 400, ours)],   // parented to another live Ratbat
            bundledBinary: ours,
            ownPID: 91973
        )
        XCTAssertEqual(found, [], "another instance's child is not an orphan")
    }

    func testNeverReapsItself() {
        let found = TunnelReaper.orphans(
            among: [p(91973, 1, ours)],
            bundledBinary: ours,
            ownPID: 91973
        )
        XCTAssertEqual(found, [])
    }

    func testExplicitlyExcludedChildPIDsAreSpared() {
        let found = TunnelReaper.orphans(
            among: [p(777, 1, ours)],
            bundledBinary: ours,
            ownPID: 91973,
            ownChildPIDs: [777]
        )
        XCTAssertEqual(found, [], "a pid we know is ours is never reaped")
    }

    /// A build running from DerivedData is a different bundle; its orphans
    /// are not ours to reap.
    func testDoesNotReapADifferentBundlesBinary() {
        let other = "/Users/jonas/Library/Developer/Xcode/DerivedData/Ratbat-x/Build/Products/Debug/Ratbat.app/Contents/Resources/cloudflared"
        let found = TunnelReaper.orphans(
            among: [p(600, 1, other)],
            bundledBinary: ours,
            ownPID: 91973
        )
        XCTAssertEqual(found, [])
    }

    func testMixedTablePicksOnlyTheOrphan() {
        let table = [
            p(38305, 1, somebodyElses),      // unrelated service
            p(96657, 96649, ours),           // our live child
            p(95338, 1, ours),               // the orphan
            p(1, 0, "/sbin/launchd"),
        ]
        XCTAssertEqual(
            TunnelReaper.orphans(among: table, bundledBinary: ours, ownPID: 96649),
            [95338]
        )
    }

    func testEmptyTableIsSafe() {
        XCTAssertEqual(
            TunnelReaper.orphans(among: [], bundledBinary: ours, ownPID: 1),
            []
        )
    }

    // MARK: - Parsing `ps -axo pid=,ppid=,comm=`

    func testParsesRealPsOutput() {
        let text = """
        38305     1 /opt/homebrew/bin/cloudflared
        96657 96649 /Applications/Ratbat.app/Contents/Resources/cloudflared
        """
        let rows = TunnelReaper.parseProcessTable(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], p(38305, 1, somebodyElses))
        XCTAssertEqual(rows[1], p(96657, 96649, ours))
    }

    /// The path is the last column and may contain spaces, so it is the
    /// remainder of the line — not whitespace field 3, which would truncate.
    func testParsesAPathContainingSpaces() {
        let rows = TunnelReaper.parseProcessTable(
            "42 1 /Applications/My Radio.app/Contents/Resources/cloudflared"
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].executablePath, "/Applications/My Radio.app/Contents/Resources/cloudflared")
        XCTAssertEqual(rows[0].pid, 42)
    }

    func testSkipsMalformedLinesRatherThanGuessing() {
        let rows = TunnelReaper.parseProcessTable("""

        not-a-pid 1 /bin/thing
        7 notappid /bin/thing
        99 1
        12 1 /ok/path
        """)
        XCTAssertEqual(rows.map(\.pid), [12], "only the well-formed row survives")
    }

    func testHandlesLeadingWhitespaceFromPsColumnPadding() {
        let rows = TunnelReaper.parseProcessTable("  70797     1 \(ours)")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].pid, 70797)
        XCTAssertEqual(rows[0].parentPID, 1)
        XCTAssertEqual(rows[0].executablePath, ours)
    }

    /// End to end on the shape `ps` actually emits: parse, then filter.
    func testParseThenReapOnARealisticTable() {
        let text = """
        38305     1 /opt/homebrew/bin/cloudflared
        70797     1 \(ours)
        96657 96649 \(ours)
        """
        let found = TunnelReaper.orphans(
            among: TunnelReaper.parseProcessTable(text),
            bundledBinary: ours,
            ownPID: 96649
        )
        XCTAssertEqual(found, [70797], "only our leaked replica")
    }
}
