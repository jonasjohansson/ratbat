#if os(macOS)
import XCTest
@testable import RatbatCore

final class HistoryStoreTests: XCTestCase {
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

    func testRecordAndHasPlayed() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        let before = try await store.hasPlayed(station: station, artist: "X", title: "Y")
        XCTAssertFalse(before)
        _ = try await store.record(station: station, artist: "X", title: "Y")
        let after = try await store.hasPlayed(station: station, artist: "X", title: "Y")
        XCTAssertTrue(after)
    }

    func testPlayThroughCount_sumsAndScopesPerStation() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let s1 = UUID(), s2 = UUID()
        let a = try await store.record(station: s1, artist: "Aphex Twin", title: "Xtal")
        let b = try await store.record(station: s1, artist: "Aphex Twin", title: "Ageispolis")
        let c = try await store.record(station: s2, artist: "Aphex Twin", title: "Xtal")

        let initial = try await store.playThroughCount(forStation: s1, artist: "Aphex Twin")
        XCTAssertEqual(initial, 0)
        try await store.incrementPlayCount(id: a)
        try await store.incrementPlayCount(id: a)
        try await store.incrementPlayCount(id: b)
        try await store.incrementPlayCount(id: c)

        // s1 sums across both of the artist's rows (2 + 1 = 3).
        let s1Count = try await store.playThroughCount(forStation: s1, artist: "aphex twin")
        XCTAssertEqual(s1Count, 3)
        // s2 is scoped separately (just c).
        let s2Count = try await store.playThroughCount(forStation: s2, artist: "Aphex Twin")
        XCTAssertEqual(s2Count, 1)
        // Unknown artist → 0.
        let unknown = try await store.playThroughCount(forStation: s1, artist: "Nobody")
        XCTAssertEqual(unknown, 0)
    }

    func testPlayThroughRecencyWeight_decaysWithAge() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let s = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day = 86_400.0

        // Same artist, three play-throughs at increasing age.
        let recent = try await store.record(station: s, artist: "Boards of Canada", title: "Roygbiv", playedAt: now)
        let mid = try await store.record(station: s, artist: "Boards of Canada", title: "Telephasic", playedAt: now.addingTimeInterval(-30 * day))
        let old = try await store.record(station: s, artist: "Boards of Canada", title: "Olson", playedAt: now.addingTimeInterval(-60 * day))
        try await store.incrementPlayCount(id: recent)
        try await store.incrementPlayCount(id: mid)
        try await store.incrementPlayCount(id: old)

        // With a 30-day half-life: 1.0 (today) + 0.5 (30d) + 0.25 (60d).
        let weighted = try await store.playThroughRecencyWeight(
            forStation: s, artist: "boards of canada", halfLifeDays: 30, now: now
        )
        XCTAssertEqual(weighted, 1.75, accuracy: 0.01)

        // The un-decayed count still sees all three equally.
        let raw = try await store.playThroughCount(forStation: s, artist: "Boards of Canada")
        XCTAssertEqual(raw, 3)

        // Unknown artist → 0.
        let none = try await store.playThroughRecencyWeight(
            forStation: s, artist: "Nobody", halfLifeDays: 30, now: now
        )
        XCTAssertEqual(none, 0)
    }

    func testTopAffinityArtists_ranksBySavesAndPlays() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        // Artist A: one save (weight 3). Artist B: two play-throughs
        // (weight 2). Artist C: recorded but no engagement (excluded).
        let a = try await store.record(station: station, artist: "Artist A", title: "a1")
        try await store.markSaved(id: a, cachedPath: "/tmp/a.m4a")
        let b = try await store.record(station: station, artist: "Artist B", title: "b1")
        try await store.incrementPlayCount(id: b)
        try await store.incrementPlayCount(id: b)
        _ = try await store.record(station: station, artist: "Artist C", title: "c1")

        let ranked = try await store.topAffinityArtists(forStation: station, limit: 5)
        XCTAssertEqual(ranked, ["Artist A", "Artist B"], "saved artist outranks played; unengaged excluded")
    }

    func testTopAffinityArtists_scopedPerStation() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let s1 = UUID(), s2 = UUID()
        let x = try await store.record(station: s1, artist: "Only On S1", title: "t")
        try await store.markSaved(id: x, cachedPath: "/tmp/x.m4a")
        let s2Ranked = try await store.topAffinityArtists(forStation: s2, limit: 5)
        XCTAssertTrue(s2Ranked.isEmpty, "affinity is station-scoped")
    }

    func testDedupIsCaseInsensitive() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        _ = try await store.record(station: station, artist: "Boards of Canada", title: "Roygbiv")
        let hit = try await store.hasPlayed(station: station, artist: "boards of canada", title: " ROYGBIV ")
        XCTAssertTrue(hit)
    }

    func testDedupScopedPerStation() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let s1 = UUID(), s2 = UUID()
        _ = try await store.record(station: s1, artist: "A", title: "B")
        let s1hit = try await store.hasPlayed(station: s1, artist: "A", title: "B")
        let s2hit = try await store.hasPlayed(station: s2, artist: "A", title: "B")
        XCTAssertTrue(s1hit)
        XCTAssertFalse(s2hit)
    }

    func testMarkSavedUpdatesFlag() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        let rowid = try await store.record(
            station: station, artist: "A", title: "B",
            cachedPath: "/tmp/a.m4a"
        )
        var unsaved = try await store.unsavedCachedEntries()
        XCTAssertEqual(unsaved.count, 1)
        try await store.markSaved(id: rowid, cachedPath: "/final/a.m4a")
        unsaved = try await store.unsavedCachedEntries()
        XCTAssertEqual(unsaved.count, 0)
        let saved = try await store.savedEntries(forStation: station)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.cachedPath, "/final/a.m4a")
    }

    func testPlayedTodayWindow() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        // Record one today, one a week ago
        _ = try await store.record(station: station, artist: "Today", title: "Now")
        _ = try await store.record(
            station: station, artist: "Week ago", title: "Past",
            playedAt: Date().addingTimeInterval(-7 * 86400)
        )
        let today = try await store.playedToday()
        XCTAssertEqual(today.count, 1)
        XCTAssertEqual(today.first?.artist, "Today")
    }

    func testPersistenceAcrossInstances() async throws {
        do {
            let store = try await HistoryStore(databaseURL: tempURL)
            _ = try await store.record(station: UUID(), artist: "A", title: "B")
        }
        // Reopen
        let store = try await HistoryStore(databaseURL: tempURL)
        let reopened = try await store.unsavedCachedEntries()
        // unsavedCachedEntries requires cachedPath != nil; the entry we
        // recorded had nil. So this should return empty AND NOT throw.
        XCTAssertEqual(reopened.count, 0)
    }

    func testNormalize() {
        XCTAssertEqual(HistoryStore.normalize("  Hello   World  "), "hello world")
        XCTAssertEqual(HistoryStore.normalize("Drake's"), "drake's")
    }

    // MARK: - v2 schema (taste-intelligence)

    func testMarkSkippedRecordsSkip() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        let rowid = try await store.record(
            station: station, artist: "Groove Coverage", title: "Poison"
        )
        try await store.markSkipped(id: rowid)
        let skipped = try await store.skippedEntries(forStation: station)
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?.artist, "Groove Coverage")
    }

    func testHasSkippedCaseInsensitive() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let station = UUID()
        let rowid = try await store.record(
            station: station, artist: "Scooter", title: "Fire"
        )
        try await store.markSkipped(id: rowid)
        let hit = try await store.hasSkipped(station: station, artist: "scooter")
        XCTAssertTrue(hit)
        let miss = try await store.hasSkipped(station: station, artist: "Miles Davis")
        XCTAssertFalse(miss)
    }

    func testSkipIsScopedPerStation() async throws {
        let store = try await HistoryStore(databaseURL: tempURL)
        let s1 = UUID(), s2 = UUID()
        let rowid = try await store.record(station: s1, artist: "A", title: "B")
        try await store.markSkipped(id: rowid)
        let hitS1 = try await store.hasSkipped(station: s1, artist: "A")
        let hitS2 = try await store.hasSkipped(station: s2, artist: "A")
        XCTAssertTrue(hitS1)
        XCTAssertFalse(hitS2)
    }

    func testV2SchemaReopensCleanly() async throws {
        // First open creates / migrates a fresh v2 DB.
        _ = try await HistoryStore(databaseURL: tempURL)
        // Reopening shouldn't re-run the migration or throw.
        let store = try await HistoryStore(databaseURL: tempURL)
        let rowid = try await store.record(station: UUID(), artist: "X", title: "Y")
        // Would fail with "no such column" if the v2 migration didn't stick.
        try await store.markSkipped(id: rowid)
    }
}
#endif

// MARK: - Migration replayability (batch 6 pre-check)

extension HistoryStoreTests {
    /// Reproduces an interrupted migration.
    ///
    /// Each step runs non-idempotent `ALTER TABLE ... ADD COLUMN` outside
    /// any transaction and bumps `PRAGMA user_version` only afterwards, so
    /// a crash or a deploy's `killall` between the two leaves a database
    /// whose columns exist but whose recorded version says they do not.
    ///
    /// Simulated by winding `user_version` back with the columns left in
    /// place — byte-identical to what an interrupted migration leaves.
    func testInterruptedMigrationCanStillBeOpened() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-\(UUID().uuidString).sqlite")

        // Fully migrated, healthy database.
        _ = try await HistoryStore(databaseURL: url)

        // Wind the version back, leaving the new columns present.
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [url.path, "PRAGMA user_version = 1;"]
        try sqlite.run()
        sqlite.waitUntilExit()

        // Must still open. Re-running an already-applied ALTER must not be
        // fatal — every generative station depends on this store, and the
        // single construction site swallows the throw with `try?`.
        _ = try await HistoryStore(databaseURL: url)
    }

    /// Answers the question that matters for anyone who already has a
    /// broken history.db: does this RECOVER one, or only stop new ones?
    ///
    /// It recovers, because the ALTERs are now skipped when the column is
    /// already there — so replaying the interrupted step succeeds, the
    /// version bump lands, and the existing rows are untouched.
    func testAlreadyBrokenDatabaseIsRecoveredNotJustPrevented() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recover-\(UUID().uuidString).sqlite")

        // A real database with real content.
        let original = try await HistoryStore(databaseURL: url)
        _ = try await original.record(
            station: UUID(),
            artist: "Before The Break",
            title: "Row One",
            sourceShowURL: URL(string: "https://example.com")!,
            youtubeID: "abc",
            cachedPath: "/tmp/x.m4a"
        )

        // Break it exactly as an interrupted migration would.
        let wind = Process()
        wind.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        wind.arguments = [url.path, "PRAGMA user_version = 1;"]
        try wind.run(); wind.waitUntilExit()

        // Reopen with the fixed ladder.
        let recovered = try await HistoryStore(databaseURL: url)

        let version = Process()
        version.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        version.arguments = [url.path, "PRAGMA user_version;"]
        let pipe = Pipe(); version.standardOutput = pipe
        try version.run(); version.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            out, String(HistoryStore.latestSchemaVersion),
            "version was not repaired"
        )

        let rows = try await recovered.recentEntries(limit: 10)
        XCTAssertTrue(
            rows.contains { $0.artist == "Before The Break" },
            "recovery must not lose existing history"
        )
    }

    // MARK: - Heartbeat: outage vs quiet

    /// The whole point of the table.
    ///
    /// history.db records a row only when a track plays, so "the station
    /// was off air" and "the station was on air and nobody queued
    /// anything" are the same absence of rows. After the fact they are
    /// indistinguishable, which is why an overnight outage could not be
    /// dated.
    ///
    /// A heartbeat row per station per interval separates them.
    func testHeartbeatDistinguishesOffAirFromQuiet() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: url)

        let quiet = UUID()    // on air the whole window, played nothing
        let offAir = UUID()   // not running at all
        let playing = UUID()  // on air and playing

        let now = Date()
        let windowStart = now.addingTimeInterval(-3_600)
        // Ends slightly ahead: the play below is recorded after `now` is
        // captured, and a window that excludes it would make the assertion
        // test the clock rather than the feature.
        let windowEnd = now.addingTimeInterval(300)

        // Quiet station: heartbeats, no plays.
        for minutesAgo in stride(from: 55, through: 5, by: -10) {
            try await store.recordHeartbeat(
                station: quiet,
                at: now.addingTimeInterval(-Double(minutesAgo) * 60),
                listeners: 0
            )
        }
        // Playing station: heartbeats AND a play.
        for minutesAgo in stride(from: 55, through: 5, by: -10) {
            try await store.recordHeartbeat(
                station: playing,
                at: now.addingTimeInterval(-Double(minutesAgo) * 60),
                listeners: 1
            )
        }
        _ = try await store.record(
            station: playing,
            artist: "Someone",
            title: "Something",
            sourceShowURL: URL(string: "https://example.com")!,
            youtubeID: "y",
            cachedPath: "/tmp/a.m4a"
        )
        // Off-air station: nothing at all.

        // history alone cannot tell these apart — that is the defect.
        let quietPlays = try await store.recentEntries(forStation: quiet, limit: 10).count
        let offAirPlays = try await store.recentEntries(forStation: offAir, limit: 10).count
        XCTAssertEqual(quietPlays, 0)
        XCTAssertEqual(offAirPlays, 0)
        XCTAssertEqual(quietPlays, offAirPlays, "history cannot discriminate; that is why heartbeat exists")

        // The heartbeat table can.
        let quietState = try await store.liveness(station: quiet, from: windowStart, to: windowEnd)
        let offAirState = try await store.liveness(station: offAir, from: windowStart, to: windowEnd)
        let playingState = try await store.liveness(station: playing, from: windowStart, to: windowEnd)

        XCTAssertEqual(quietState, .onAirButQuiet, "an on-air station with no plays must not read as an outage")
        XCTAssertEqual(offAirState, .offAir, "a station with no heartbeats in the window was off air")
        XCTAssertEqual(playingState, .onAirAndPlaying)
        XCTAssertNotEqual(quietState, offAirState, "the two must be distinguishable — the point of the feature")
    }

    /// A gap inside the window is datable: when did it stop, when did it
    /// come back.
    func testHeartbeatGapIsDatable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hbgap-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: url)
        let station = UUID()
        let now = Date()

        // On air 60-40 min ago, dark 40-20, back 20-0.
        for m in [60, 55, 50, 45, 40] {
            try await store.recordHeartbeat(station: station, at: now.addingTimeInterval(-Double(m) * 60), listeners: 0)
        }
        for m in [20, 15, 10, 5, 0] {
            try await store.recordHeartbeat(station: station, at: now.addingTimeInterval(-Double(m) * 60), listeners: 0)
        }

        let gaps = try await store.offAirGaps(
            station: station,
            from: now.addingTimeInterval(-3_600),
            to: now,
            expectedInterval: 300
        )
        XCTAssertEqual(gaps.count, 1, "expected exactly one gap, got \(gaps)")
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gap.duration, 20 * 60, accuracy: 90, "gap should be ~20 minutes, was \(gap.duration)s")
    }

    /// Retention: the table must not grow forever.
    func testHeartbeatRetentionPrunesOldRows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hbprune-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: url)
        let station = UUID()
        let now = Date()

        try await store.recordHeartbeat(station: station, at: now.addingTimeInterval(-40 * 86_400), listeners: 0)
        try await store.recordHeartbeat(station: station, at: now.addingTimeInterval(-1 * 86_400), listeners: 0)

        let pruned = try await store.pruneHeartbeats(olderThan: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(pruned, 1, "the 40-day-old row should have been pruned")

        let remaining = try await store.heartbeats(
            station: station,
            from: now.addingTimeInterval(-365 * 86_400),
            to: now
        )
        XCTAssertEqual(remaining.count, 1)
    }
}
