#if os(macOS)
import XCTest
@testable import RatbatCore

/// Fixture-backed tests for ``NTSClient``. These never hit the live
/// network — they decode captured API responses checked into
/// `RatbatCore/Tests/Fixtures/nts/` so future NTS markup/shape changes
/// produce locally reproducible failures.
///
/// NTS is a React SPA; the useful data lives behind their public JSON API
/// at `/api/v2/`. The fixtures are snapshots of that JSON (see the file's
/// class docs for a transport summary), not HTML.
final class NTSClientTests: XCTestCase {

    // MARK: - Parsing: shows list

    func testParseShowsFromTagPage() async throws {
        let data = try fixtureData("shows-ambient.json")
        let client = NTSClient()
        let sourceURL = URL(string: "https://www.nts.live/api/v2/shows")!
        let shows = try await client.parseShows(from: data, tag: "ambient", sourceURL: sourceURL)

        XCTAssertGreaterThan(shows.count, 0, "ambient query should yield at least one show")
        XCTAssertTrue(shows.allSatisfy { !$0.title.isEmpty }, "every show must have a non-empty title")
        XCTAssertTrue(shows.allSatisfy { $0.url.host?.contains("nts.live") == true },
                      "every show URL must be on nts.live")
        // Every returned show must carry at least one ambient-like tag, by
        // definition of the substring filter.
        XCTAssertTrue(shows.allSatisfy { show in
            show.tags.contains(where: { $0.lowercased().contains("ambient") })
        }, "filter must only keep shows whose genres contain the tag")
        // ID == show_alias (stable slug) — exercise against the known
        // "dont-trip" entry in the fixture.
        XCTAssertTrue(shows.contains(where: { $0.id == "dont-trip" }),
                      "fixture includes 'dont-trip' (Dark Ambient) which must pass the ambient filter")
    }

    // MARK: - Parsing: tracklist

    func testParseTracklistFromShowPage() async throws {
        let data = try fixtureData("tracklist-dream-catalogue.json")
        let client = NTSClient()
        let fakeShowURL = URL(string:
            "https://www.nts.live/shows/dream-catalogue/episodes/dream-catalogue-30th-october-2019"
        )!

        let tracks = try await client.parseTracklist(from: data, showURL: fakeShowURL)

        XCTAssertGreaterThan(tracks.count, 0, "show page fixture should yield a tracklist")
        XCTAssertTrue(tracks.allSatisfy { !$0.artist.isEmpty && !$0.title.isEmpty })
        // Positions are 1-based and contiguous.
        XCTAssertEqual(tracks.map(\.position), Array(1...tracks.count))
        // Spot-check the first track against the captured fixture so a
        // shape change (e.g. NTS renaming `artist` → `performer`) breaks
        // the test loudly rather than silently.
        XCTAssertEqual(tracks.first?.artist, "DCT")
        XCTAssertEqual(tracks.first?.title, "Sine Arrangements For UDP Worshippers")
        XCTAssertEqual(tracks.first?.showURL, fakeShowURL)
    }

    // MARK: - Failure modes

    func testMalformedJSONThrows() async {
        let client = NTSClient()
        let url = URL(string: "https://www.nts.live/shows/example")!
        let garbage = Data("<html>nothing here</html>".utf8)
        do {
            _ = try await client.parseTracklist(from: garbage, showURL: url)
            XCTFail("expected malformed error for non-JSON bytes")
        } catch let err as NTSClient.Error {
            if case .malformed(let u, _) = err {
                XCTAssertEqual(u, url)
            } else {
                XCTFail("expected .malformed, got \(err)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Fixture loading

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        // Try the folder-reference path first (project.yml ships Fixtures
        // as a `type: folder` resource).
        if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/nts") {
            return try Data(contentsOf: url)
        }
        // Fall back to flattened layouts just in case.
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return try Data(contentsOf: url)
        }
        if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("nts")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
        }
        throw XCTSkip("Fixture Fixtures/nts/\(name) not bundled — check project.yml test target resources")
    }
}
#endif
