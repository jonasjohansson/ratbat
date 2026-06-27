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

    func testParseSimilarArtists_preservesMatchOrder() async throws {
        let fixture = """
        {
          "similarartists": {
            "artist": [
              {"name": "Boards of Canada", "match": "1.0"},
              {"name": "Bibio", "match": "0.71"},
              {"name": "", "match": "0.4"},
              {"name": "Tycho", "match": "0.33"}
            ]
          }
        }
        """.data(using: .utf8)!
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        let parsed = try await client.parseSimilarArtists(from: fixture, sourceURL: sourceURL)
        // Blank-name row dropped, order preserved (Last.fm pre-sorts by match).
        XCTAssertEqual(parsed, ["Boards of Canada", "Bibio", "Tycho"])
    }

    func testParseSimilarArtists_apiError_throws() async {
        let fixture = """
        { "error": 6, "message": "No artist found" }
        """.data(using: .utf8)!
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        do {
            _ = try await client.parseSimilarArtists(from: fixture, sourceURL: sourceURL)
            XCTFail("expected an apiError")
        } catch LastFMClient.Error.apiError(let code, _) {
            XCTAssertEqual(code, 6)
        } catch {
            XCTFail("wrong error kind: \(error)")
        }
    }

    func testParseArtistTopTracks_extractsCandidates() async throws {
        let fixture = """
        {
          "toptracks": {
            "track": [
              {"name": "Roygbiv", "artist": {"name": "Boards of Canada"},
               "listeners": "412000", "playcount": "3100000"},
              {"name": "", "artist": {"name": "Boards of Canada"}},
              {"name": "Olson", "artist": {"name": "Boards of Canada"}}
            ]
          }
        }
        """.data(using: .utf8)!
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        let parsed = try await client.parseArtistTopTracks(from: fixture, sourceURL: sourceURL)
        // Blank-title row dropped.
        XCTAssertEqual(parsed.map(\.title), ["Roygbiv", "Olson"])
        XCTAssertEqual(parsed.first?.artist, "Boards of Canada")
        XCTAssertEqual(parsed.first?.listeners, 412000)
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
