#if os(macOS)
import XCTest
@testable import RatbatCore

/// Tests for ``NTSStationController``.
///
/// The controller composes three actors (NTSClient, HistoryStore,
/// TrackResolver) and only its NTS/history sides are cheap to stand
/// up in a test. ``TrackResolver`` wraps a Python subprocess and needs
/// a real venv, so we don't invoke `nextTrack()` here — that belongs
/// in an end-to-end / smoke test with real services.
///
/// These tests cover:
/// - ``NTSStationConfig`` Codable round-trip + defaults
/// - Controller construction with real (non-network) collaborators
final class NTSStationControllerTests: XCTestCase {

    // MARK: - Config

    func testConfigCodableRoundTrip() throws {
        let cfg = NTSStationConfig(
            name: "Saturday Ambient",
            tags: ["ambient", "drone"],
            yearMin: 2020,
            yearMax: 2026,
            shufflePool: false
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(NTSStationConfig.self, from: data)
        XCTAssertEqual(decoded, cfg)
        XCTAssertEqual(decoded.id, cfg.id)
        XCTAssertEqual(decoded.tags, ["ambient", "drone"])
        XCTAssertEqual(decoded.yearMin, 2020)
        XCTAssertEqual(decoded.yearMax, 2026)
        XCTAssertFalse(decoded.shufflePool)
    }

    func testConfigDefaults() {
        let cfg = NTSStationConfig(name: "X", tags: ["y"])
        XCTAssertEqual(cfg.name, "X")
        XCTAssertEqual(cfg.tags, ["y"])
        XCTAssertNil(cfg.yearMin)
        XCTAssertNil(cfg.yearMax)
        XCTAssertTrue(cfg.shufflePool)
    }

    func testConfigIdentityStableAcrossEncode() throws {
        let cfg = NTSStationConfig(name: "Ambient", tags: ["ambient"])
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

        let cfg = NTSStationConfig(name: "Test", tags: ["ambient"])
        let controller = NTSStationController(
            config: cfg,
            nts: nts,
            history: history,
            resolver: resolver
        )
        // Just confirm construction succeeded; don't drive the state
        // machine (that requires the network + venv).
        _ = controller
    }
}
#endif
