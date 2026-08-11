#if os(macOS)
import XCTest
@testable import RatbatCore

/// History rows are stored against a station's stable UUID, but `/history`
/// threw that id away and published a NAME instead — resolved from the
/// currently-broadcasting pipelines only, and from a `Station` snapshot
/// frozen at broadcast start.
///
/// Two failures fell out of that. A row whose station wasn't live right now
/// got `"station": ""` — 90 of 214 rows in the real database, all identity
/// silently gone. And a station renamed while live kept publishing its old
/// name, which is why rows read `"station": "Techno (2)"` for a station
/// called "Techno".
///
/// These tests pin the id to the wire and make the name a lookup against
/// the live station catalogue rather than a snapshot.
final class HistoryStationIdentityTests: XCTestCase {

    /// Every row carries its stable `stationID`. The display `name` is
    /// resolved from the saved station catalogue — so it covers stations
    /// that aren't broadcasting — and is `null`, not `""`, when the station
    /// is genuinely gone.
    @MainActor
    func testRowsCarryStableIDAndCatalogueResolvedName() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-id-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.port = 18_070
        defer { prefs.port = 18_000 }

        let live = Station(name: "Live Station", kind: .playlist(queue: []))
        let idle = Station(name: "Idle Station", kind: .playlist(queue: []))
        let goneID = UUID()

        for (station, title) in [(live.id, "Live Track"), (idle.id, "Idle Track"), (goneID, "Orphan Track")] {
            _ = try await store.record(station: station, artist: "A", title: title)
        }

        let radio = RadioBroadcaster(
            preferences: prefs, history: store, publishesPublicly: false
        )
        // The catalogue is what the sidebar shows — both saved stations,
        // broadcasting or not.
        radio.registerStations([live, idle])

        let payload = await radio.buildHistoryPayload(path: "/history")
        let rows = try Self.rows(from: payload)

        let byTitle = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
                guard let t = row["title"] as? String else { return nil }
                return (t, row)
            }
        )

        let liveRow = try XCTUnwrap(byTitle["Live Track"])
        XCTAssertEqual(liveRow["stationID"] as? String, live.id.uuidString)
        XCTAssertEqual(liveRow["station"] as? String, "Live Station")

        let idleRow = try XCTUnwrap(byTitle["Idle Track"])
        XCTAssertEqual(
            idleRow["stationID"] as? String, idle.id.uuidString,
            "a station that isn't broadcasting still has an identity"
        )
        XCTAssertEqual(idleRow["station"] as? String, "Idle Station")

        let orphanRow = try XCTUnwrap(byTitle["Orphan Track"])
        XCTAssertEqual(
            orphanRow["stationID"] as? String, goneID.uuidString,
            "a deleted station's rows keep their id — the row is not anonymous"
        )
        XCTAssertTrue(
            orphanRow["station"] is NSNull,
            "unknown station reports null, not an empty string"
        )
    }

    /// Renaming a station while it broadcasts must change the name on the
    /// wire. The pipeline froze a `Station` value at start, so `/now.json`
    /// and `/history` went on publishing the old name until the next
    /// restart.
    @MainActor
    func testRenamingALiveStationUpdatesTheWire() async throws {
        guard let tracks = try await Self.fixtureTracks() else {
            throw XCTSkip("Fixtures missing")
        }
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-rename-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.port = 18_071
        defer { prefs.port = 18_000 }

        var station = Station(name: "Techno (2)", kind: .playlist(queue: tracks))
        _ = try await store.record(station: station.id, artist: "A", title: "T")

        let radio = RadioBroadcaster(
            preferences: prefs, history: store, publishesPublicly: false
        )
        radio.registerStations([station])
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }
        try await Task.sleep(nanoseconds: 400_000_000)

        station.name = "Techno"
        radio.registerStations([station])

        let payload = await radio.buildHistoryPayload(path: "/history")
        let rows = try Self.rows(from: payload)
        XCTAssertEqual(rows.first?["station"] as? String, "Techno")

        let (nowData, _) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:18071/now.json")!
        )
        let now = try JSONSerialization.jsonObject(with: nowData) as? [String: Any]
        let stations = now?["stations"] as? [[String: Any]] ?? []
        XCTAssertEqual(stations.first?["name"] as? String, "Techno")
        XCTAssertEqual(
            stations.first?["slug"] as? String, "techno",
            "the stream path follows the new name too"
        )
    }

    /// The slug is derived from the name, so renaming a live station moves
    /// its stream path. The "was live when we last ran" record is keyed by
    /// slug — leave the stale one behind and the next launch tries to
    /// resume a station that no longer answers to that path.
    @MainActor
    func testRenameCarriesTheResumeIntentToTheNewSlug() async throws {
        guard let tracks = try await Self.fixtureTracks() else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.port = 18_072
        prefs.lastLiveSlugs = []
        defer {
            prefs.port = 18_000
            prefs.lastLiveSlugs = []
        }

        var station = Station(name: "Before Rename", kind: .playlist(queue: tracks))
        let radio = RadioBroadcaster(preferences: prefs, publishesPublicly: false)
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }
        XCTAssertEqual(prefs.lastLiveSlugs, ["before-rename"])

        station.name = "After Rename"
        radio.registerStations([station])

        XCTAssertEqual(
            prefs.lastLiveSlugs, ["after-rename"],
            "resume intent follows the station, not the old path"
        )
    }

    /// Registering stations must not resurrect a pipeline for one that
    /// isn't broadcasting, and must not disturb a live station it doesn't
    /// mention.
    @MainActor
    func testRegisteringStationsLeavesUnrelatedPipelinesAlone() async throws {
        guard let tracks = try await Self.fixtureTracks() else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.port = 18_073
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, publishesPublicly: false)
        let station = Station(name: "Untouched", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        radio.registerStations([Station(name: "Somebody Else", kind: .playlist(queue: []))])

        XCTAssertTrue(radio.isBroadcasting(stationID: station.id))
        let (data, _) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:18073/now.json")!
        )
        let now = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let stations = now?["stations"] as? [[String: Any]] ?? []
        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations.first?["name"] as? String, "Untouched")
    }

    // MARK: - Helpers

    nonisolated static func rows(from payload: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return json?["entries"] as? [[String: Any]] ?? []
    }

    nonisolated static func fixtureTracks() async throws -> [Track]? {
        let bundle = Bundle(for: HistoryStationIdentityTests.self)
        guard let root = bundle.url(
            forResource: "library", withExtension: nil, subdirectory: "Fixtures"
        ) ?? bundle.resourceURL?.appendingPathComponent("Fixtures/library") else {
            return nil
        }
        let playlists = try await LibraryIndexer().scan(folder: root)
        guard let tracks = playlists.first?.tracks, !tracks.isEmpty else { return nil }
        return tracks
    }
}
#endif
