#if os(macOS)
import XCTest
@testable import RatbatCore

final class TasteProfileTests: XCTestCase {

    private func track(_ artist: String, genre: String? = nil) -> Track {
        Track(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).m4a"),
            title: "t",
            artist: artist,
            album: "",
            duration: 1,
            genre: genre
        )
    }

    // MARK: - Library-derived signals

    func testLibraryProfile_ranksArtistsByTrackCount() async {
        let profile = TasteProfile()
        await profile.ingestLibrary([
            track("Miles"),
            track("Miles"),
            track("Monk")
        ])
        let miles = await profile.libraryArtistScore(for: "Miles")
        let monk = await profile.libraryArtistScore(for: "Monk")
        let unknown = await profile.libraryArtistScore(for: "Justin Bieber")
        XCTAssertEqual(miles, 1.0, accuracy: 0.01)
        XCTAssertEqual(monk, 0.5, accuracy: 0.01)
        XCTAssertEqual(unknown, 0.0, accuracy: 0.01)
    }

    func testLibraryContainsArtist_exactOnly() async {
        let profile = TasteProfile()
        await profile.ingestLibrary([track("Portishead")])
        let contains = await profile.libraryContainsArtist("Portishead")
        let missing = await profile.libraryContainsArtist("Portis Head")
        XCTAssertTrue(contains)
        XCTAssertFalse(missing)
    }

    func testLibraryTagScore_normalizesCase() async {
        let profile = TasteProfile()
        await profile.ingestLibrary([
            track("A", genre: "Techno"),
            track("B", genre: "techno"),
            track("C", genre: "ambient")
        ])
        let techno = await profile.libraryTagScore(for: "techno")
        let Techno = await profile.libraryTagScore(for: "Techno")
        let ambient = await profile.libraryTagScore(for: "ambient")
        XCTAssertEqual(techno, 1.0, accuracy: 0.01)
        XCTAssertEqual(Techno, 1.0, accuracy: 0.01)       // case-insensitive
        XCTAssertEqual(ambient, 0.5, accuracy: 0.01)
    }

    func testLibraryProfile_ignoresBlankArtists() async {
        let profile = TasteProfile()
        await profile.ingestLibrary([
            track(""),
            track("   "),
            track("Real Artist")
        ])
        let score = await profile.libraryArtistScore(for: "Real Artist")
        XCTAssertEqual(score, 1.0, accuracy: 0.01)
    }

    // MARK: - Scoring (library + behavioral)

    private func makeHistoryStore() async throws -> HistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID()).db")
        return try await HistoryStore(databaseURL: url)
    }

    func testScore_libraryArtist_boostsCandidate() async throws {
        let profile = TasteProfile()
        await profile.ingestLibrary([track("Miles")])
        let history = try await makeHistoryStore()
        let stationID = UUID()
        let score = await profile.score(
            candidateArtist: "Miles",
            candidateTags: [],
            stationID: stationID,
            history: history
        )
        XCTAssertGreaterThan(score, 0.2)
    }

    func testScore_skippedArtist_isHardBlacklist() async throws {
        let profile = TasteProfile()
        await profile.ingestLibrary([track("Miles")])
        let history = try await makeHistoryStore()
        let stationID = UUID()
        // Record + skip the artist on this station.
        let rowid = try await history.record(
            station: stationID, artist: "Miles", title: "Ugh"
        )
        try await history.markSkipped(id: rowid)
        let score = await profile.score(
            candidateArtist: "Miles",
            candidateTags: [],
            stationID: stationID,
            history: history
        )
        XCTAssertLessThan(score, 0)       // blacklisted
    }

    func testScore_savedArtist_addsAffinity() async throws {
        let profile = TasteProfile()
        await profile.ingestLibrary([])   // empty library — isolate save signal
        let history = try await makeHistoryStore()
        let stationID = UUID()
        // Record a play and mark as saved so the save-affinity kicks in.
        let rowid = try await history.record(
            station: stationID, artist: "Portishead", title: "Glory Box",
            cachedPath: "/tmp/x.m4a"
        )
        try await history.markSaved(id: rowid, cachedPath: "/final/x.m4a")
        let candidate = await profile.score(
            candidateArtist: "Portishead",
            candidateTags: [],
            stationID: stationID,
            history: history
        )
        let stranger = await profile.score(
            candidateArtist: "Someone Else",
            candidateTags: [],
            stationID: stationID,
            history: history
        )
        XCTAssertGreaterThan(candidate, stranger)
    }

    func testScore_saveAffinity_isGraduatedByCount() async throws {
        // More saves of the same artist on a station should yield a
        // strictly higher score than a single save — the signal is
        // graduated, not binary.
        let profile = TasteProfile()
        await profile.ingestLibrary([])   // empty library — isolate save signal
        let history = try await makeHistoryStore()

        func scoreAfterSaves(_ n: Int) async throws -> Double {
            let station = UUID()
            for i in 0..<n {
                let rowid = try await history.record(
                    station: station, artist: "Aphex Twin", title: "Track \(i)",
                    cachedPath: "/tmp/\(i).m4a"
                )
                try await history.markSaved(id: rowid, cachedPath: "/final/\(i).m4a")
            }
            return await profile.score(
                candidateArtist: "Aphex Twin",
                candidateTags: [],
                stationID: station,
                history: history
            )
        }

        let one = try await scoreAfterSaves(1)
        let three = try await scoreAfterSaves(3)
        let none = try await scoreAfterSaves(0)
        XCTAssertGreaterThan(one, none, "one save should beat no saves")
        XCTAssertGreaterThan(three, one, "three saves should beat one save")
    }

    func testScore_tagOverlap_boostsCandidate() async throws {
        let profile = TasteProfile()
        await profile.ingestLibrary([
            track("A", genre: "techno"),
            track("B", genre: "techno"),
            track("C", genre: "ambient")
        ])
        let history = try await makeHistoryStore()
        let stationID = UUID()
        let technoCand = await profile.score(
            candidateArtist: "Unknown DJ",
            candidateTags: ["techno"],
            stationID: stationID,
            history: history
        )
        let taglessCand = await profile.score(
            candidateArtist: "Unknown DJ",
            candidateTags: [],
            stationID: stationID,
            history: history
        )
        XCTAssertGreaterThan(technoCand, taglessCand)
    }

    // MARK: - Persistence round-trip

    func testTasteProfileStore_roundTripsSnapshot() throws {
        let snapshot = TasteProfileSnapshot(
            libraryArtists: ["Miles": 1.0, "Monk": 0.5],
            libraryTags: ["jazz": 1.0]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("taste-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try TasteProfileStore.save(snapshot, to: url)
        let loaded = try TasteProfileStore.load(from: url)
        XCTAssertEqual(loaded.libraryArtists["Miles"], 1.0)
        XCTAssertEqual(loaded.libraryTags["jazz"], 1.0)
    }
}
#endif
