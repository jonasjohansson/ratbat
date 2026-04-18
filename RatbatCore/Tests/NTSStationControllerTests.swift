#if os(macOS)
import XCTest
@testable import RatbatCore

/// Tests for ``NTSStationController``.
///
/// The controller composes up to six actors (NTSClient, MusicBrainzClient,
/// optional LastFMClient, HistoryStore, TrackResolver, TasteProfile) and
/// only the network-free sides are cheap to stand up here.
/// ``TrackResolver`` wraps a Python subprocess and needs a real venv, so
/// we don't invoke `nextTrack()` — that belongs in an end-to-end / smoke
/// test with real services. ``MusicBrainzClient`` is constructed because
/// the new init signature requires it; it makes no network calls in
/// these tests (no stage that would trigger one is exercised).
///
/// These tests cover:
/// - ``NTSStationConfig`` Codable round-trip + defaults
/// - Controller construction with real (non-network) collaborators
final class NTSStationControllerTests: XCTestCase {

    // MARK: - Config

    func testConfigCodableRoundTrip() throws {
        let cfg = NTSStationConfig(
            name: "Saturday Ambient",
            query: FacetedQuery(
                genreTags: ["ambient", "drone"],
                yearMin: 2020,
                yearMax: 2026
            ),
            shufflePool: false
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(NTSStationConfig.self, from: data)
        XCTAssertEqual(decoded, cfg)
        XCTAssertEqual(decoded.id, cfg.id)
        XCTAssertEqual(decoded.query.genreTags, ["ambient", "drone"])
        XCTAssertEqual(decoded.query.yearMin, 2020)
        XCTAssertEqual(decoded.query.yearMax, 2026)
        XCTAssertFalse(decoded.shufflePool)
    }

    func testConfigDefaults() {
        let cfg = NTSStationConfig(name: "X", query: FacetedQuery(genreTags: ["y"]))
        XCTAssertEqual(cfg.name, "X")
        XCTAssertEqual(cfg.query.genreTags, ["y"])
        XCTAssertNil(cfg.query.yearMin)
        XCTAssertNil(cfg.query.yearMax)
        XCTAssertTrue(cfg.shufflePool)
    }

    func testConfigIdentityStableAcrossEncode() throws {
        let cfg = NTSStationConfig(name: "Ambient", query: FacetedQuery(genreTags: ["ambient"]))
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(NTSStationConfig.self, from: data)
        // Station id must survive round-trip — HistoryStore dedup keys off it.
        XCTAssertEqual(decoded.id, cfg.id)
    }

    // MARK: - Construction

    /// Integration-style sanity check: the controller composes cleanly
    /// with a real ``NTSClient``, a real ephemeral ``HistoryStore``, and
    /// a ``TrackResolver`` pointed at dummy paths. We don't call
    /// `nextTrack()` — that would hit the live NTS API and a Python
    /// subprocess. This just verifies the wiring compiles + initializes.
    func testConstructsWithRealServices() async throws {
        let nts = NTSClient()
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nts-controller-\(UUID()).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let history = try HistoryStore(databaseURL: dbURL)

        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nts-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: cacheRoot
        )

        let cfg = NTSStationConfig(name: "Test", query: FacetedQuery(genreTags: ["ambient"]))
        let mb = MusicBrainzClient(userAgent: "Ratbat/test (jns.johansson@gmail.com)")
        let profile = TasteProfile()
        let controller = NTSStationController(
            config: cfg,
            nts: nts,
            musicBrainz: mb,
            lastFM: nil,
            history: history,
            resolver: resolver,
            tasteProfile: profile
        )
        // Just confirm construction succeeded; don't drive the state
        // machine (that requires the network + venv).
        _ = controller
    }
}
#endif
