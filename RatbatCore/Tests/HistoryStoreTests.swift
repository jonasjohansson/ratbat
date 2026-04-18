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
