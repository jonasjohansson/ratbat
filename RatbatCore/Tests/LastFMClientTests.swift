#if os(macOS)
import XCTest
@testable import RatbatCore

final class LastFMClientTests: XCTestCase {

    func testParseArtistTopTags_sortsByCountDescending() async throws {
        // Trimmed fixture modelled on Last.fm's real envelope — `count`
        // is the relevance weight on a 0-100 scale.
        let fixture = """
        {
          "toptags": {
            "tag": [
              {"name": "Eurodance", "count": 100},
              {"name": "Dance", "count": 88},
              {"name": "Pop", "count": 72},
              {"name": "", "count": 5},
              {"name": "Techno", "count": 12}
            ]
          }
        }
        """.data(using: .utf8)!
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        let parsed = try await client.parseArtistTopTags(from: fixture, sourceURL: sourceURL)
        // Empty-name row dropped, remaining four sorted desc by count.
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(parsed.map(\.name), ["eurodance", "dance", "pop", "techno"])
        XCTAssertEqual(parsed[0].count, 100)
    }

    func testParseArtistTopTags_emptyEnvelope_returnsEmpty() async throws {
        let fixture = """
        { "toptags": { "tag": [] } }
        """.data(using: .utf8)!
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        let parsed = try await client.parseArtistTopTags(from: fixture, sourceURL: sourceURL)
        XCTAssertTrue(parsed.isEmpty)
    }

    func testParseArtistTopTags_apiError_throws() async {
        let fixture = """
        { "error": 6, "message": "No artist found with that name" }
        """.data(using: .utf8)!
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        do {
            _ = try await client.parseArtistTopTags(from: fixture, sourceURL: sourceURL)
            XCTFail("expected an apiError")
        } catch LastFMClient.Error.apiError(let code, _) {
            XCTAssertEqual(code, 6)
        } catch {
            XCTFail("wrong error kind: \(error)")
        }
    }
}
#endif
