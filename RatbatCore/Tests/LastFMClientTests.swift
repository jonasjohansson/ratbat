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

    // MARK: - artist.getinfo / track.getinfo (/trackinfo enrichment)

    func testParseArtistInfo_extractsFieldsAndStripsBio() async throws {
        // Trimmed from a real artist.getinfo response: numbers as
        // strings, HTML in the bio, and the "Read more" boilerplate
        // Last.fm appends to every `content` blob.
        let fixture = Data(#"""
        {
          "artist": {
            "name": "Boards of Canada",
            "stats": {"listeners": "1412000", "playcount": "93100000"},
            "similar": {"artist": [
              {"name": "Aphex Twin"}, {"name": "Bibio"}, {"name": ""}
            ]},
            "tags": {"tag": [{"name": "IDM"}, {"name": "Electronic"}, {"name": ""}]},
            "bio": {
              "summary": "short",
              "content": "Boards of Canada are a Scottish duo &amp; siblings. <a href=\"https://www.last.fm/music/Boards+of+Canada\">Read more on Last.fm</a>. User-contributed text is available under the Creative Commons By-SA License."
            }
          }
        }
        """#.utf8)
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        let parsed = try await client.parseArtistInfo(from: fixture, sourceURL: sourceURL)
        // Bio is plain text: entity decoded, anchor gone, everything from
        // "Read more" onward (link text + license sentence) cut.
        XCTAssertEqual(parsed.bio, "Boards of Canada are a Scottish duo & siblings.")
        XCTAssertEqual(parsed.listeners, 1_412_000)
        XCTAssertEqual(parsed.playcount, 93_100_000)
        // Tags lowercased (the artistTopTags rule), blanks dropped.
        XCTAssertEqual(parsed.tags, ["idm", "electronic"])
        // Similar keeps casing — names are display text.
        XCTAssertEqual(parsed.similar, ["Aphex Twin", "Bibio"])
    }

    func testParseArtistInfo_emptyEnvelope_answersAllNulls() async throws {
        // An unknown-but-not-erroring artist: envelope present, nothing
        // in it. Every field degrades rather than throwing — /trackinfo
        // renders nulls, not a 500.
        let fixture = Data(#"{ "artist": {} }"#.utf8)
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        let parsed = try await client.parseArtistInfo(from: fixture, sourceURL: sourceURL)
        XCTAssertNil(parsed.bio)
        XCTAssertNil(parsed.listeners)
        XCTAssertNil(parsed.playcount)
        XCTAssertTrue(parsed.tags.isEmpty)
        XCTAssertTrue(parsed.similar.isEmpty)
    }

    func testParseArtistInfo_apiError_throws() async {
        let fixture = Data(#"{ "error": 6, "message": "The artist you supplied could not be found" }"#.utf8)
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        do {
            _ = try await client.parseArtistInfo(from: fixture, sourceURL: sourceURL)
            XCTFail("expected an apiError")
        } catch LastFMClient.Error.apiError(let code, _) {
            XCTAssertEqual(code, 6)
        } catch {
            XCTFail("wrong error kind: \(error)")
        }
    }

    func testParseTrackInfo_extractsFields() async throws {
        let fixture = Data(#"""
        {
          "track": {
            "name": "Roygbiv",
            "listeners": "412000",
            "playcount": "3100000",
            "album": {"title": "Music Has the Right to Children"},
            "toptags": {"tag": [{"name": "IDM"}, {"name": "Downtempo"}]},
            "wiki": {"summary": "A <b>seminal</b> track. <a href=\"https://www.last.fm/music/x\">Read more on Last.fm</a>."}
          }
        }
        """#.utf8)
        let client = LastFMClient(apiKey: "x")
        let sourceURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        let parsed = try await client.parseTrackInfo(from: fixture, sourceURL: sourceURL)
        XCTAssertEqual(parsed.album, "Music Has the Right to Children")
        XCTAssertEqual(parsed.listeners, 412_000)
        XCTAssertEqual(parsed.playcount, 3_100_000)
        XCTAssertEqual(parsed.tags, ["idm", "downtempo"])
        XCTAssertEqual(parsed.wiki, "A seminal track.")
    }

    func testPlainBio_capsAtSentenceBoundary() {
        // 40 sentences of 40 chars = 1600 chars, over the cap. The cut
        // must land on a sentence end inside the cap, never mid-word.
        let sentence = "This sentence is forty characters long!"
        let long = Array(repeating: sentence, count: 40).joined(separator: " ")
        guard let capped = LastFMClient.plainBio(long) else {
            XCTFail("a long plain-text bio must survive the cap")
            return
        }
        XCTAssertLessThanOrEqual(capped.count, LastFMClient.bioCharacterCap)
        XCTAssertTrue(capped.hasSuffix("!"), "cut mid-sentence: …\(capped.suffix(50))")
        // Nothing-but-markup reduces to nothing, and says so with nil
        // rather than an empty string the client would render as a blank
        // card.
        XCTAssertNil(LastFMClient.plainBio("<p>  </p>"))
        XCTAssertNil(LastFMClient.plainBio(nil))
    }

    func testArtistInfoSingleFlight_coalescesConcurrentFetches() async throws {
        // Two concurrent asks for the same artist (case differs — the
        // cache key is lowercased) must produce ONE upstream request,
        // and a later ask is served from the 24h cache: /trackinfo is
        // polled, and the poll must not multiply into API traffic.
        StubURLProtocol.reset()
        StubURLProtocol.set([
            "/2.0?method=artist.getinfo&artist=Bibio&autocorrect=1&api_key=test&format=json": Data(#"""
                {"artist":{"stats":{"listeners":"5","playcount":"9"},"bio":{"summary":"Hi there."}}}
                """#.utf8)
        ])
        defer { StubURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = LastFMClient(
            apiKey: "test",
            session: URLSession(configuration: configuration)
        )

        async let first = client.artistInfo("Bibio")
        async let second = client.artistInfo("bibio")
        let (a, b) = try await (first, second)
        // The lowercased ask rode the in-flight task — had it fetched on
        // its own, the stub would have answered its unknown URL with the
        // empty default and the two results would differ.
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.bio, "Hi there.")
        XCTAssertEqual(
            StubURLProtocol.requestedKeys().count, 1,
            "two concurrent asks, one upstream fetch: \(StubURLProtocol.requestedKeys())"
        )

        _ = try await client.artistInfo("Bibio")
        XCTAssertEqual(
            StubURLProtocol.requestedKeys().count, 1,
            "a repeat ask inside the TTL must be served from cache"
        )
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
    // MARK: - Name collisions

    /// Last.fm keys artists by name, so "uro" the Bandcamp composer is
    /// handed URO the Danish anarcho-punk band. The record is flagged so
    /// the wire can drop it instead of describing the wrong musician.
    func testArtistInfoFlagsLastFMsDisambiguationEntries() throws {
        let enumerated = LastFMClient.ArtistInfo(
            bio: "1) Anarcho-punk from Denmark with female vocals and cello. 2) URO are based in Lecce (Italy).",
            listeners: 11600, playcount: 90000, tags: ["crust"], similar: ["Paragraf 119"])
        XCTAssertTrue(enumerated.isAmbiguous, "an entry that starts at 1) is a list of namesakes")

        let preamble = LastFMClient.ArtistInfo(
            bio: "There is more than one artist with this name, including: Caribou is Canadian Dan Snaith…",
            listeners: 1, playcount: 1, tags: [], similar: [])
        XCTAssertTrue(preamble.isAmbiguous, "so is the explicit preamble")

        let plain = LastFMClient.ArtistInfo(
            bio: "MJ Cole (born Matthew James Firth Coleman, 1973) is a house and UK garage producer.",
            listeners: 331_900, playcount: 1, tags: ["uk garage"], similar: ["Wookie"])
        XCTAssertFalse(plain.isAmbiguous, "a biography about one artist is not a collision")

        XCTAssertFalse(
            LastFMClient.ArtistInfo(bio: nil, listeners: nil, playcount: nil, tags: [], similar: []).isAmbiguous,
            "no biography is not evidence of a collision")
    }

    /// The enumeration is hand-typed, so its punctuation is whatever the
    /// editor felt like. A Bandcamp producer called FAFA was handed an
    /// Indonesian rapper and a Connecticut punk band merged into one
    /// biography because the check tested for "1)" and the page began
    /// "1 )" — one space.
    func testDisambiguationSurvivesTheEditorsPunctuation() throws {
        let info = { (bio: String) in
            LastFMClient.ArtistInfo(bio: bio, listeners: 882, playcount: 1, tags: [], similar: [])
        }
        let listed = [
            "1 )  Indonesian female rapper\n\n2)   Meriden, Connecticut punk rock band",
            "1) A band from Leeds\n2) A producer from Osaka",
            "1. A band from Leeds\n2. A producer from Osaka",
            "1 - A band from Leeds\n2 - A producer from Osaka",
            "FAFA may refer to two unrelated acts.",
            "There are several artists with this name.",
            // Found in the wild after the first pass shipped: the
            // enumeration follows a sentence of preamble rather than
            // opening the entry, and the preamble is worded in a way the
            // first list of phrases did not cover. A disco track credited
            // to "Horns And Drums" was handed this.
            "There are at least 7 bands called Horns.\n\n1) A raw black metal from Chile.\n\n2) A black metal band from Poland.",
            "There are at least two artists using this name.",
            "Two bands named Mirror have released records.",
        ]
        for bio in listed {
            XCTAssertTrue(info(bio).isAmbiguous, "should read as a list: \(bio.prefix(40))")
        }

        // A leading "1" is only a list if a "2" follows it, or every
        // biography that opens with a year would be thrown away.
        let single = [
            "1963 was the year Bernard Wright was born in Queens, New York.",
            "1. was how they titled the debut, and there was never a second.",
            "Bernard Wright was an American keyboardist, born in Queens in 1963.",
        ]
        for bio in single {
            XCTAssertFalse(info(bio).isAmbiguous, "should read as one artist: \(bio.prefix(40))")
        }
    }
}

#endif
