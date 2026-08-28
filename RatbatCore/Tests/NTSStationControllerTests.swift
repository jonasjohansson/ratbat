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

    // MARK: - A station must not fold because it has been listening a while

    /// Build a controller with fake services, so `nextTrack()` can be driven
    /// without the live NTS API or a Python subprocess.
    private func makeController(
        history: HistoryStore,
        name: String = "Techno"
    ) throws -> NTSStationController {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nts-cache-\(UUID())")
        let resolver = try TrackResolver(
            venvPython: URL(fileURLWithPath: "/bin/echo"),
            wrapperScript: URL(fileURLWithPath: "/dev/null"),
            cacheRoot: cacheRoot
        )
        return NTSStationController(
            config: NTSStationConfig(name: name, query: FacetedQuery(genreTags: ["techno"])),
            nts: NTSClient(),
            musicBrainz: MusicBrainzClient(userAgent: "Ratbat/test (jns.johansson@gmail.com)"),
            lastFM: nil,
            history: history,
            resolver: resolver,
            tasteProfile: TasteProfile()
        )
    }

    private func makeHistory() throws -> (HistoryStore, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nts-budget-\(UUID()).db")
        return (try HistoryStore(databaseURL: dbURL), dbURL)
    }

    private static func resolution(_ title: String) -> TrackResolver.Resolution {
        TrackResolver.Resolution(
            cachedURL: URL(fileURLWithPath: "/tmp/\(UUID()).m4a"),
            youtubeID: "vid-\(abs(title.hashValue))",
            matchedTitle: title,
            fileSize: 1234
        )
    }

    /// The regression that took NTS Techno off air and made the website
    /// report it offline.
    ///
    /// Already-played tracks used to spend the same budget as unusable ones.
    /// The station had 28 plays and two tracks the resolver could not match:
    /// 28 + 2 = 30 = maxAttempts, so it threw poolExhausted on the FIRST
    /// track, which surfaces as `nil` and ends the station. The bug scaled
    /// with success — every station folds once its play count reaches the
    /// cap.
    func testStationSurvivesAPoolMostlyAlreadyPlayed() async throws {
        let (history, dbURL) = try makeHistory()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let controller = try makeController(history: history)
        let stationID = await controller.stationIDForTesting

        // 40 already-played tracks — comfortably past the 30 cap.
        var candidates: [SourceCandidate] = []
        for i in 0..<40 {
            let artist = "Played Artist \(i)", title = "Played Title \(i)"
            _ = try await history.record(
                station: stationID, artist: artist, title: title,
                sourceShowURL: URL(string: "https://www.nts.live/")!,
                youtubeID: "old-\(i)", cachedPath: "/tmp/old-\(i).m4a"
            )
            candidates.append(SourceCandidate(artist: artist, title: title))
        }
        // ...then one fresh track sitting right behind them.
        candidates.append(SourceCandidate(artist: "Fresh Artist", title: "Fresh Title"))

        await controller.seedPoolForTesting(candidates)
        await controller.setResolveOverrideForTesting { _, title in Self.resolution(title) }

        let track = try await controller.nextTrack()
        XCTAssertEqual(track.title, "Fresh Title",
                       "40 dedup skips must not exhaust the candidate budget")
    }

    /// One track the resolver cannot match must cost one candidate, not the
    /// station.
    func testStationSurvivesATrackThatCannotResolve() async throws {
        let (history, dbURL) = try makeHistory()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let controller = try makeController(history: history)

        await controller.seedPoolForTesting([
            SourceCandidate(artist: "FACTA _", title: "DUMB HUMMER"),      // real NO_MATCH
            SourceCandidate(artist: "52 Street", title: "Look Into My Eyes"), // real NO_MATCH
            SourceCandidate(artist: "Good Artist", title: "Good Title"),
        ])
        await controller.setResolveOverrideForTesting { artist, title in
            if artist == "Good Artist" { return Self.resolution(title) }
            throw TrackResolver.Error.noYouTubeMatch(artist: artist, title: title)
        }

        let track = try await controller.nextTrack()
        XCTAssertEqual(track.title, "Good Title",
                       "an unresolvable track must be skipped, not end the station")
    }

    /// Genuine exhaustion must still be reported — the fix must not make a
    /// truly empty pool spin forever.
    func testATrulyUnresolvablePoolStillReportsExhaustion() async throws {
        let (history, dbURL) = try makeHistory()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let controller = try makeController(history: history)

        await controller.seedPoolForTesting(
            (0..<5).map { SourceCandidate(artist: "Nope \($0)", title: "Nope \($0)") }
        )
        await controller.setResolveOverrideForTesting { artist, title in
            throw TrackResolver.Error.noYouTubeMatch(artist: artist, title: title)
        }

        // Note: with every seeded candidate unusable, this falls through to
        // `refillPool()`, which reaches the live NTS API. A network failure
        // there is not what this test is about, so it skips rather than
        // failing red for an unrelated reason.
        do {
            _ = try await controller.nextTrack()
            XCTFail("a pool where nothing resolves must report exhaustion")
        } catch let error as NTSStationController.Error {
            if case .transientResolveFailure = error {
                throw XCTSkip("NTS unreachable; exhaustion path not exercised")
            }
            XCTAssertTrue(error.endsStation, "genuine exhaustion still ends the station")
        } catch is CancellationError {
            throw XCTSkip("cancelled")
        } catch {
            throw XCTSkip("NTS unreachable (\(type(of: error))); exhaustion path not exercised")
        }
    }
}
#endif
