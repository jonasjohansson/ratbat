#if os(macOS)
import XCTest
@testable import RatbatCore

/// Covers the unified ``Station/Kind`` model added alongside the NTS
/// station creation UI — Codable round-trips for each variant, the
/// convenience accessors, and ``StationManager/createNTS(_:)`` append
/// behaviour.
final class StationKindTests: XCTestCase {

    func testPlaylistKindCodableRoundTrip() throws {
        let track = Track(
            url: URL(fileURLWithPath: "/fake/a.m4a"),
            title: "A",
            artist: "X",
            album: "L",
            duration: 100
        )
        let station = Station(name: "P", kind: .playlist(queue: [track]))
        let data = try JSONEncoder().encode(station)
        let decoded = try JSONDecoder().decode(Station.self, from: data)

        XCTAssertEqual(decoded.id, station.id)
        XCTAssertEqual(decoded.name, "P")
        XCTAssertEqual(decoded.queue.count, 1)
        XCTAssertEqual(decoded.queue.first?.title, "A")
        XCTAssertNil(decoded.ntsConfig)
    }

    func testNTSKindCodableRoundTrip() throws {
        let config = NTSStationConfig(
            name: "Saturday Ambient",
            tags: ["ambient", "ECM"],
            yearMin: 2020,
            yearMax: 2026
        )
        let station = Station.fromNTS(config)
        let data = try JSONEncoder().encode(station)
        let decoded = try JSONDecoder().decode(Station.self, from: data)

        XCTAssertEqual(decoded.id, config.id)
        XCTAssertEqual(decoded.name, "Saturday Ambient")
        XCTAssertEqual(decoded.ntsConfig?.tags, ["ambient", "ECM"])
        XCTAssertEqual(decoded.ntsConfig?.yearMin, 2020)
        XCTAssertEqual(decoded.ntsConfig?.yearMax, 2026)
        XCTAssertTrue(decoded.queue.isEmpty)
    }

    /// `fromNTS` must reuse the config's id so HistoryStore dedup keys
    /// remain stable across broadcaster restarts.
    func testFromNTSReusesConfigID() {
        let config = NTSStationConfig(name: "T", tags: ["ambient"])
        let station = Station.fromNTS(config)
        XCTAssertEqual(station.id, config.id)
    }

    @MainActor
    func testCreateNTSAppendsToStations() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("smgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mgr = StationManager()
        mgr.setStorage(root: tempRoot)
        XCTAssertEqual(mgr.stations.count, 0)

        mgr.createNTS(NTSStationConfig(name: "T", tags: ["ambient"]))
        XCTAssertEqual(mgr.stations.count, 1)
        XCTAssertNotNil(mgr.stations.first?.ntsConfig)
        XCTAssertEqual(mgr.stations.first?.name, "T")
    }

    /// Collision-check: creating two NTS stations with the same name
    /// must disambiguate the second's visible name so the derived slug
    /// stays unique — matches the existing playlist-station flow.
    @MainActor
    func testCreateNTSDisambiguatesDuplicateName() {
        let mgr = StationManager()
        mgr.createNTS(NTSStationConfig(name: "Chill", tags: ["ambient"]))
        let second = mgr.createNTS(
            NTSStationConfig(name: "Chill", tags: ["ambient"])
        )
        XCTAssertEqual(mgr.stations.count, 2)
        XCTAssertNotEqual(mgr.stations[0].slug, mgr.stations[1].slug)
        XCTAssertTrue(second.name.contains("(2)"))
    }

    func testStationKind_bandcamp_roundTrips() throws {
        let cfg = BandcampStationConfig(name: "X", query: FacetedQuery(genreTags: ["t"]))
        let station = Station.fromBandcamp(cfg)
        let data = try JSONEncoder().encode(station)
        let decoded = try JSONDecoder().decode(Station.self, from: data)
        XCTAssertEqual(decoded.bandcampConfig?.name, "X")
        XCTAssertEqual(decoded.bandcampConfig?.query.genreTags, ["t"])
    }

    /// A createNTS-authored station survives a save/load round-trip
    /// through ``StationStore`` — the Kind enum's `.nts` case must be
    /// covered by the file format's Codable schema.
    @MainActor
    func testCreateNTSPersists() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("smgr-nts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let first = StationManager()
        first.setStorage(root: tempRoot)
        let created = first.createNTS(
            NTSStationConfig(name: "Night Drive", tags: ["downtempo", "dub"])
        )

        let second = StationManager()
        second.setStorage(root: tempRoot)
        XCTAssertEqual(second.stations.count, 1)
        XCTAssertEqual(second.stations.first?.id, created.id)
        XCTAssertEqual(
            second.stations.first?.ntsConfig?.tags.sorted(),
            ["downtempo", "dub"]
        )
    }
}
#endif
