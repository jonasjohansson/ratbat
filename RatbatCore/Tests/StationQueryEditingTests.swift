#if os(macOS)
import XCTest
@testable import RatbatCore

/// A station's tags could not be changed. `StationManager` exposed
/// `rename` and `delete` and nothing else, so "same station, different
/// genres" meant delete + recreate — which mints a NEW UUID and orphans
/// every history row the station ever wrote. (90 of 214 rows in the
/// production database are orphans of exactly that manoeuvre.)
///
/// The model was already shaped for editing: `Station.kind` is `var` and
/// each config holds a `var query: FacetedQuery`. These tests pin editing
/// in place — same id, same config id, new facets, persisted — and the
/// explicit restart that makes a live station pick the change up.
@MainActor
final class StationQueryEditingTests: XCTestCase {

    // MARK: - Editing keeps identity

    /// The whole point: the station and its config keep their ids, so
    /// history, dedup and taste signals stay attached to it.
    func testEditingQueryKeepsStationAndConfigIdentity() throws {
        let root = try Self.tempRoot()
        let manager = Self.manager(root: root)

        let nts = manager.createNTS(NTSStationConfig(
            name: "NTS", query: FacetedQuery(genreTags: ["ambient"])
        ))
        let lastFM = manager.createLastFM(LastFMStationConfig(
            name: "LastFM", query: FacetedQuery(genreTags: ["jazz"])
        ))
        let bandcamp = manager.createBandcamp(BandcampStationConfig(
            name: "Bandcamp", query: FacetedQuery(genreTags: ["techno"])
        ))

        let newQuery = FacetedQuery(
            genreTags: ["dub techno", "drone"], yearMin: 1995, yearMax: 2005,
            regions: ["DE"], tagMatch: .all
        )

        for original in [nts, lastFM, bandcamp] {
            let updated = try XCTUnwrap(
                manager.updateQuery(original.id, to: newQuery),
                "editing \(original.name) should succeed"
            )
            XCTAssertEqual(updated.id, original.id, "station id must not move")
            XCTAssertEqual(
                Self.query(of: updated), newQuery,
                "the new facets should be what the station now carries"
            )
            XCTAssertEqual(
                Self.configID(of: updated), Self.configID(of: original),
                "the config id is the history dedup key — it must not move either"
            )
            XCTAssertEqual(updated.name, original.name, "editing tags is not renaming")
        }
    }

    /// The edit has to survive a relaunch, or the station reverts to its
    /// old tags the next time the app opens.
    func testEditedQueryIsPersisted() throws {
        let root = try Self.tempRoot()
        let manager = Self.manager(root: root)
        let station = manager.createBandcamp(BandcampStationConfig(
            name: "Persisted", query: FacetedQuery(genreTags: ["techno"])
        ))
        _ = manager.updateQuery(station.id, to: FacetedQuery(genreTags: ["hyperpop"]))

        let reloaded = Self.manager(root: root)
        let found = try XCTUnwrap(reloaded.stations.first(where: { $0.id == station.id }))
        XCTAssertEqual(Self.query(of: found)?.genreTags, ["hyperpop"])
    }

    /// A playlist station has no faceted query to edit — its tracks come
    /// from a fixed queue. Report that by refusing, rather than by
    /// silently doing nothing and looking like success.
    func testEditingAPlaylistStationRefuses() throws {
        let root = try Self.tempRoot()
        let manager = Self.manager(root: root)
        let station = manager.create(from: Playlist(
            name: "Fixed", folder: nil, tracks: [], children: [], kind: .folder
        ))
        XCTAssertNil(manager.updateQuery(station.id, to: FacetedQuery(genreTags: ["x"])))
        XCTAssertEqual(manager.stations.count, 1)
    }

    func testEditingAnUnknownStationRefuses() throws {
        let root = try Self.tempRoot()
        let manager = Self.manager(root: root)
        XCTAssertNil(manager.updateQuery(UUID(), to: FacetedQuery(genreTags: ["x"])))
    }

    /// Bandcamp's sort is the one knob that lives outside the shared
    /// query, and the add sheet offers it — so the edit path has to too,
    /// or editing would quietly be able to do less than creating.
    func testEditingBandcampSortKeepsIdentity() throws {
        let root = try Self.tempRoot()
        let manager = Self.manager(root: root)
        let station = manager.createBandcamp(BandcampStationConfig(
            name: "Sort", query: FacetedQuery(genreTags: ["techno"]), sort: .date
        ))
        let updated = try XCTUnwrap(manager.updateBandcampSort(station.id, to: .pop))
        XCTAssertEqual(updated.id, station.id)
        XCTAssertEqual(updated.bandcampConfig?.sort, .pop)
        XCTAssertEqual(updated.bandcampConfig?.query.genreTags, ["techno"])
    }

    // MARK: - Picking the edit up on a live station

    /// Editing tags while the station is on air does nothing to the sound
    /// until the pool is rebuilt, and the pool is only built at broadcast
    /// start. `restartBroadcast` is the explicit, named way to do that —
    /// it must end with the station live again, carrying the new config,
    /// and still recorded as live so the next launch resumes it.
    @MainActor
    func testRestartRebuildsTheStationWithItsNewConfig() async throws {
        guard let tracks = try await Self.fixtureTracks() else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.port = 18_080
        prefs.lastLiveSlugs = []
        defer {
            prefs.port = 18_000
            prefs.lastLiveSlugs = []
        }
        let radio = RadioBroadcaster(preferences: prefs, publishesPublicly: false)

        // A playlist station stands in for "the pipeline is rebuilt from
        // the value handed to startBroadcast" — the same mechanism a
        // generative station's pool refill rides on, without needing a
        // live network stack in a unit test.
        var station = Station(name: "Restartable", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(radio.isBroadcasting(stationID: station.id))

        station.kind = .playlist(queue: Array(tracks.prefix(1)))
        await radio.restartBroadcast(station: station)

        XCTAssertTrue(
            radio.isBroadcasting(stationID: station.id),
            "a restart ends with the station back on air"
        )
        XCTAssertEqual(
            prefs.lastLiveSlugs, [station.slug],
            "a restart is not the owner switching the station off"
        )
    }

    /// Restarting something that isn't on air just starts it. The edit
    /// sheet calls this unconditionally when the user saves, so the
    /// off-air case has to be harmless rather than an error.
    @MainActor
    func testRestartingAnIdleStationSimplyStartsIt() async throws {
        guard let tracks = try await Self.fixtureTracks() else {
            throw XCTSkip("Fixtures missing")
        }
        let prefs = BroadcastPreferences()
        prefs.port = 18_081
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, publishesPublicly: false)
        let station = Station(name: "Was Idle", kind: .playlist(queue: tracks))

        await radio.restartBroadcast(station: station)
        defer { radio.stopAll() }
        XCTAssertTrue(radio.isBroadcasting(stationID: station.id))
    }

    // MARK: - Helpers

    static func manager(root: URL) -> StationManager {
        let manager = StationManager()
        manager.setStorage(root: root)
        return manager
    }

    static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("station-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func query(of station: Station) -> FacetedQuery? {
        switch station.kind {
        case .playlist: return nil
        case .nts(let c): return c.query
        case .lastFM(let c): return c.query
        case .bandcamp(let c): return c.query
        case .libraryRadio(let c): return c.query
        }
    }

    static func configID(of station: Station) -> UUID? {
        switch station.kind {
        case .playlist: return nil
        case .nts(let c): return c.id
        case .lastFM(let c): return c.id
        case .bandcamp(let c): return c.id
        case .libraryRadio(let c): return c.id
        }
    }

    nonisolated static func fixtureTracks() async throws -> [Track]? {
        let bundle = Bundle(for: StationQueryEditingTests.self)
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
