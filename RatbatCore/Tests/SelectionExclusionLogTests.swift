#if os(macOS)
import XCTest
import SQLite3
@testable import RatbatCore

/// The audit trail for the mix-set filter: every candidate the selection
/// rule drops gets a durable, readable row. A silent filter that cannot be
/// audited turns into a quieter, worse station with no way to diagnose it,
/// so these tests treat the log as part of the feature.
final class SelectionExclusionLogTests: XCTestCase {
    var tempURL: URL!

    override func setUp() async throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID()).db")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL)
        // WAL/SHM sidecars — remove too so a re-run of the same URL is clean.
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    // MARK: - Migration

    func testFreshDatabaseLandsAtV4() async throws {
        _ = try await HistoryStore(databaseURL: tempURL)
        XCTAssertEqual(try readUserVersion(), 4)
    }

    func testV3DatabaseMigratesToV4WithoutDataLoss() async throws {
        try seedV3Database(
            rows: [("Coil", "Tattooed Man"), ("Gas", "Pop 1")]
        )
        XCTAssertEqual(try readUserVersion(), 3, "precondition: seeded DB is v3")

        let store = try await HistoryStore(databaseURL: tempURL)
        XCTAssertEqual(try readUserVersion(), 4)

        let survivors = try await store.recentEntries(limit: 50)
        XCTAssertEqual(survivors.map(\.artist).sorted(), ["Coil", "Gas"])

        // And the new table is usable on the migrated DB.
        let station = UUID()
        try await store.recordExclusions([sample(artist: "Eliane Radigue")], stationID: station)
        let logged = try await store.exclusions(stationID: station, limit: 10)
        XCTAssertEqual(logged.count, 1)
    }

    func testMigrationIsIdempotentAcrossReopens() async throws {
        let station = UUID()
        do {
            let store = try await HistoryStore(databaseURL: tempURL)
            try await store.recordExclusions([sample(artist: "Stars of the Lid")], stationID: station)
        }
        // Reopening must not re-run the migration, throw, or drop the log.
        let store = try await HistoryStore(databaseURL: tempURL)
        XCTAssertEqual(try readUserVersion(), 4)
        let logged = try await store.exclusions(stationID: station, limit: 10)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.artist, "Stars of the Lid")
    }

    // MARK: - Round trip

    func testRecordAndReadRoundTrip() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://gas.bandcamp.com/album/pop")!

        try await store.recordExclusions([
            HistoryStore.ExclusionInput(
                artist: "Wolfgang Voigt",
                title: "Pop 1",
                durationSeconds: 1_512,
                durationSource: "listing-featured-track",
                arm: "duration",
                matchedText: nil,
                sourceKind: "bandcamp",
                sourceURL: url,
                enforced: true
            )
        ], stationID: station, now: at)

        let rows = try await store.exclusions(stationID: station, limit: 10)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.stationID, station)
        XCTAssertEqual(row.artist, "Wolfgang Voigt")
        XCTAssertEqual(row.title, "Pop 1")
        XCTAssertEqual(row.durationSeconds, 1_512)
        XCTAssertEqual(row.durationSource, "listing-featured-track")
        XCTAssertEqual(row.arm, "duration")
        XCTAssertNil(row.matchedText)
        XCTAssertEqual(row.sourceKind, "bandcamp")
        XCTAssertEqual(row.sourceURL, url)
        XCTAssertTrue(row.enforced)
        XCTAssertTrue(row.everEnforced)
        XCTAssertEqual(row.enforcedCount, 1)
        XCTAssertEqual(row.hitCount, 1)
        XCTAssertEqual(row.firstExcludedAt.timeIntervalSince1970, at.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(row.lastExcludedAt.timeIntervalSince1970, at.timeIntervalSince1970, accuracy: 0.001)
    }

    /// NTS and Last.fm hand us no duration at all. A NULL duration must
    /// survive the round trip as `nil`, not as 0 — 0 would read as "an
    /// instant-long track", which is a different and wrong story.
    func testNullDurationRoundTripsAsNil() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        try await store.recordExclusions([
            HistoryStore.ExclusionInput(
                artist: "NTS Guest",
                title: "Show — 2h Mix",
                durationSeconds: nil,
                durationSource: nil,
                arm: "title",
                matchedText: "mix",
                sourceKind: "nts",
                sourceURL: nil,
                enforced: false
            )
        ], stationID: station)

        let nullDurationRows = try await store.exclusions(stationID: station, limit: 10)
        let row = try XCTUnwrap(nullDurationRows.first)
        XCTAssertNil(row.durationSeconds)
        XCTAssertNil(row.durationSource)
        XCTAssertNil(row.sourceURL)
        XCTAssertEqual(row.matchedText, "mix")
        XCTAssertFalse(row.enforced)
        XCTAssertFalse(row.everEnforced)
        XCTAssertEqual(row.enforcedCount, 0)
    }

    func testBatchWriteRecordsEveryRow() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        try await store.recordExclusions(
            (1...5).map { sample(artist: "Artist \($0)") },
            stationID: station
        )
        let rows = try await store.exclusions(stationID: station, limit: 50)
        XCTAssertEqual(rows.count, 5)
    }

    // MARK: - Re-sighting

    func testResightingIncrementsHitCountAndDoesNotRewriteThePast() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(3_600)

        try await store.recordExclusions([
            HistoryStore.ExclusionInput(
                artist: "Gas", title: "Pop 1",
                durationSeconds: 1_512, durationSource: "listing-featured-track",
                arm: "duration", matchedText: "original-marker",
                sourceKind: "bandcamp", sourceURL: nil, enforced: true
            )
        ], stationID: station, now: first)

        // Same candidate, same arm, but the source now reports different
        // facts. The log records what we saw the first time; it is a log,
        // not a cache.
        try await store.recordExclusions([
            HistoryStore.ExclusionInput(
                artist: "gas", title: "  POP 1 ",
                durationSeconds: 99, durationSource: "library",
                arm: "duration", matchedText: "rewritten-marker",
                sourceKind: "bandcamp", sourceURL: nil, enforced: true
            )
        ], stationID: station, now: second)

        let rows = try await store.exclusions(stationID: station, limit: 10)
        XCTAssertEqual(rows.count, 1, "normalized key collapses the re-sighting into one row")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.hitCount, 2)
        XCTAssertEqual(row.durationSeconds, 1_512, "duration must not be rewritten on re-sighting")
        XCTAssertEqual(row.durationSource, "listing-featured-track")
        XCTAssertEqual(row.matchedText, "original-marker", "matched text must not be rewritten")
        XCTAssertEqual(row.arm, "duration")
        XCTAssertEqual(row.firstExcludedAt.timeIntervalSince1970, first.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(row.lastExcludedAt.timeIntervalSince1970, second.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(row.enforcedCount, 2)
    }

    /// Regression: a REAL drop followed by a shadow sighting must not read
    /// as "nothing was ever lost". `enforced` alone is last-write-wins, so
    /// without `ever_enforced` / `enforced_count` the row that actually ate
    /// a record last week looks harmless today and the owner concludes the
    /// filter never fired.
    func testEnforcedDropFollowedByShadowSightingKeepsEverEnforced() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()

        try await store.recordExclusions([
            HistoryStore.ExclusionInput(
                artist: "Eliane Radigue", title: "Trilogie de la Mort",
                durationSeconds: 4_200, durationSource: "library",
                arm: "duration", matchedText: nil,
                sourceKind: "library", sourceURL: nil, enforced: true
            )
        ], stationID: station, now: Date(timeIntervalSince1970: 1_700_000_000))

        // Toggle now off: we still log the sighting, but shadow-only.
        try await store.recordExclusions([
            HistoryStore.ExclusionInput(
                artist: "Eliane Radigue", title: "Trilogie de la Mort",
                durationSeconds: 4_200, durationSource: "library",
                arm: "duration", matchedText: nil,
                sourceKind: "library", sourceURL: nil, enforced: false
            )
        ], stationID: station, now: Date(timeIntervalSince1970: 1_700_003_600))

        let shadowRows = try await store.exclusions(stationID: station, limit: 10)
        let row = try XCTUnwrap(shadowRows.first)
        XCTAssertFalse(row.enforced, "enforced reflects the latest state")
        XCTAssertTrue(row.everEnforced, "the real drop last week must stay visible")
        XCTAssertEqual(row.enforcedCount, 1, "exactly one sighting actually dropped a candidate")
        XCTAssertEqual(row.hitCount, 2)
    }

    func testDifferentArmsAreLoggedSeparately() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        try await store.recordExclusions([
            HistoryStore.ExclusionInput(
                artist: "A", title: "B", durationSeconds: 3_000, durationSource: "library",
                arm: "duration", matchedText: nil, sourceKind: "library",
                sourceURL: nil, enforced: true
            ),
            HistoryStore.ExclusionInput(
                artist: "A", title: "B", durationSeconds: 3_000, durationSource: "library",
                arm: "title", matchedText: "dj set", sourceKind: "library",
                sourceURL: nil, enforced: true
            )
        ], stationID: station)

        let rows = try await store.exclusions(stationID: station, limit: 10)
        XCTAssertEqual(Set(rows.map(\.arm)), ["duration", "title"])
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - Reading

    func testExclusionsAreMostRecentFirst() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.recordExclusions([sample(artist: "Oldest")], stationID: station, now: base)
        try await store.recordExclusions([sample(artist: "Middle")], stationID: station, now: base.addingTimeInterval(60))
        try await store.recordExclusions([sample(artist: "Newest")], stationID: station, now: base.addingTimeInterval(120))

        let rows = try await store.exclusions(stationID: station, limit: 10)
        XCTAssertEqual(rows.map(\.artist), ["Newest", "Middle", "Oldest"])

        let limited = try await store.exclusions(stationID: station, limit: 2)
        XCTAssertEqual(limited.map(\.artist), ["Newest", "Middle"])
    }

    func testNilStationReadsAcrossStationsAndStationFilterScopes() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let s1 = UUID(), s2 = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.recordExclusions([sample(artist: "On S1")], stationID: s1, now: base)
        try await store.recordExclusions([sample(artist: "On S2")], stationID: s2, now: base.addingTimeInterval(60))

        let all = try await store.exclusions(stationID: nil, limit: 10)
        XCTAssertEqual(all.map(\.artist), ["On S2", "On S1"])

        let justS1 = try await store.exclusions(stationID: s1, limit: 10)
        XCTAssertEqual(justS1.map(\.artist), ["On S1"])
        XCTAssertEqual(justS1.first?.stationID, s1)
    }

    /// The same candidate on two stations is two independent records —
    /// exclusions are station-scoped like every other signal in the store.
    func testSameCandidateOnTwoStationsStaysSeparate() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let s1 = UUID(), s2 = UUID()
        try await store.recordExclusions([sample(artist: "Same", title: "Track")], stationID: s1)
        try await store.recordExclusions([sample(artist: "Same", title: "Track")], stationID: s2)
        let both = try await store.exclusions(stationID: nil, limit: 10)
        XCTAssertEqual(both.count, 2)
        let onlyS1 = try await store.exclusions(stationID: s1, limit: 10)
        XCTAssertEqual(onlyS1.first?.hitCount, 1)
    }

    // MARK: - Helpers

    private func sample(
        artist: String,
        title: String = "Some Long Thing",
        arm: String = "duration",
        enforced: Bool = true
    ) -> HistoryStore.ExclusionInput {
        HistoryStore.ExclusionInput(
            artist: artist,
            title: title,
            durationSeconds: 1_800,
            durationSource: "listing-featured-track",
            arm: arm,
            matchedText: nil,
            sourceKind: "bandcamp",
            sourceURL: URL(string: "https://example.bandcamp.com/album/x"),
            enforced: enforced
        )
    }

    /// Reads `PRAGMA user_version` on a second connection so we assert on
    /// what's actually on disk rather than on the store's own bookkeeping.
    private func readUserVersion() throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(tempURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            XCTFail("could not open \(tempURL.path) for verification")
            return -1
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            XCTFail("could not read user_version")
            return -1
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Builds a database that looks exactly like one written by the v3
    /// schema, so the v4 migration is exercised against real prior data
    /// instead of an empty file.
    private func seedV3Database(rows: [(artist: String, title: String)]) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(tempURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw HistoryStore.Error.openFailed("seed open failed")
        }
        defer { sqlite3_close(handle) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                throw HistoryStore.Error.queryFailed(msg)
            }
        }

        try exec("""
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                station_id TEXT NOT NULL,
                artist TEXT NOT NULL,
                title TEXT NOT NULL,
                artist_norm TEXT NOT NULL,
                title_norm TEXT NOT NULL,
                played_at REAL NOT NULL,
                source_show_url TEXT,
                youtube_id TEXT,
                saved INTEGER NOT NULL DEFAULT 0,
                cached_path TEXT,
                skipped INTEGER NOT NULL DEFAULT 0,
                skipped_at REAL,
                play_count INTEGER NOT NULL DEFAULT 0,
                boosted_at REAL
            );
            """)
        let station = UUID().uuidString
        for (i, r) in rows.enumerated() {
            let a = r.artist.replacingOccurrences(of: "'", with: "''")
            let t = r.title.replacingOccurrences(of: "'", with: "''")
            try exec("""
                INSERT INTO history
                  (station_id, artist, title, artist_norm, title_norm, played_at)
                VALUES ('\(station)', '\(a)', '\(t)', '\(a.lowercased())', '\(t.lowercased())',
                        \(1_700_000_000 + i));
                """)
        }
        try exec("PRAGMA user_version = 3;")
    }
}
#endif
