#if os(macOS)
import XCTest
@testable import RatbatCore

/// Parse + request-shape tests for the `/api/discover/1/discover_web`
/// client.
///
/// `bandcamp-discover-techno.json` is a REAL capture (tag `techno`, slice
/// `new`, size 48), not a hand-written sketch, because the bug that
/// prompted this migration was a live schema/behaviour drift that no
/// synthetic fixture would ever have reproduced. The synthetic fixture is
/// kept alongside it for the edge cases a real capture happens not to
/// contain.
final class BandcampClientTests: XCTestCase {

    // MARK: - Parsing the real capture

    func testParseDiscoverBatch_extractsArtistTitleURL() throws {
        let data = try fixtureJSON("bandcamp-discover-techno")
        let (releases, cursor) = BandcampClient.parseDiscoverBatch(data: data)
        XCTAssertEqual(releases.count, 48, "size:48 was requested and 48 results came back; all are parseable")
        XCTAssertEqual(cursor, "AoNw/u+RlaADCD+MzM0rYTMwNzcwODQ5MTk=", "the cursor is how the next batch is requested — losing it silently caps the pool at one page")
        let first = try XCTUnwrap(releases.first)
        XCTAssertEqual(first.title, "Come Fly With Us")
        XCTAssertEqual(first.releaseURL.scheme, "https")
        XCTAssertNotNil(first.releaseURL.host)
    }

    /// The whole reason for the migration, pinned as a parse-level fact:
    /// v3 returned the same 48 items for every tag, so nothing about a
    /// `techno` capture could ever look techno-specific. Here it can.
    func testParseDiscoverBatch_realCaptureIsTagSpecific() throws {
        let data = try fixtureJSON("bandcamp-discover-techno")
        let (releases, _) = BandcampClient.parseDiscoverBatch(data: data)
        let artists = Set(releases.map(\.artist))
        XCTAssertTrue(
            artists.contains("Detroit Techno Records") || artists.contains("Orlando Voorn"),
            "a techno capture should carry recognisably techno acts; got \(artists.sorted())"
        )
    }

    func testParseDiscoverBatch_stripsDiscoverPageQuery() throws {
        let data = try fixtureJSON("bandcamp-discover-techno")
        let (releases, _) = BandcampClient.parseDiscoverBatch(data: data)
        XCTAssertFalse(releases.isEmpty)
        for release in releases {
            XCTAssertNil(
                release.releaseURL.query,
                "`?from=discover_page` is an analytics param; it must not reach the dedup key, the history row or yt-dlp — \(release.releaseURL)"
            )
        }
        XCTAssertEqual(
            releases.first?.releaseURL.absoluteString,
            "https://camcussion.bandcamp.com/album/come-fly-with-us"
        )
    }

    func testParseDiscoverBatch_populatesFeaturedTrackTitleAndDuration() throws {
        let data = try fixtureJSON("bandcamp-discover-techno")
        let (releases, _) = BandcampClient.parseDiscoverBatch(data: data)
        let first = try XCTUnwrap(releases.first)
        XCTAssertEqual(first.featuredTrackTitle, "Mountain Tea")
        XCTAssertEqual(try XCTUnwrap(first.featuredTrackDurationSeconds), 300.488, accuracy: 0.001)

        // 47 of 48 carry a featured track. The 48th ("Get The Signal EP")
        // has `featured_track: null` and is still a real album — a missing
        // preview must not delete the release from the pool.
        let withFeatured = releases.filter { $0.featuredTrackDurationSeconds != nil }
        XCTAssertEqual(withFeatured.count, 47)
        let bare = releases.first { $0.title == "Get The Signal EP" }
        XCTAssertNotNil(bare, "an item with no featured track is still a candidate")
        XCTAssertNil(bare?.featuredTrackDurationSeconds)
        XCTAssertNil(bare?.featuredTrackTitle)
    }

    func testParseDiscoverBatch_parsesReleaseDate() throws {
        let data = try fixtureJSON("bandcamp-discover-techno")
        let (releases, _) = BandcampClient.parseDiscoverBatch(data: data)
        // "2026-08-22 00:00:00 UTC" — space-separated with a literal zone
        // name, NOT ISO 8601. A decoder that assumes ISO gets nil here.
        let date = try XCTUnwrap(releases.first?.releaseDate, "release_date must parse from Bandcamp's 'yyyy-MM-dd HH:mm:ss zzz' shape")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "GMT"))
        XCTAssertEqual(cal.component(.year, from: date), 2026)
        XCTAssertEqual(cal.component(.month, from: date), 8)
        XCTAssertEqual(cal.component(.day, from: date), 22)
        XCTAssertTrue(
            releases.allSatisfy { $0.releaseDate != nil },
            "all 48 captured items carry a release_date; a nil here means the format drifted"
        )
    }

    /// `album_artist` wins over `band_name` where the two disagree.
    /// On a label page they always disagree, and taking `band_name` there
    /// keys the dedup table, the taste profile and every MusicBrainz
    /// lookup off the label instead of the musician.
    func testParseDiscoverBatch_prefersAlbumArtistOverBandName() throws {
        let data = try fixtureJSON("bandcamp-discover-techno")
        let (releases, _) = BandcampClient.parseDiscoverBatch(data: data)
        let collab = try XCTUnwrap(releases.first { $0.title == "Come Fly With Us" })
        XCTAssertEqual(collab.artist, "camcussion & Ace Beaming Sun", "band_name is the page owner 'camcussion'; the credit is the collaboration")

        let signed = try XCTUnwrap(releases.first { $0.title == "Infected Eye EP" })
        XCTAssertEqual(signed.artist, "Orlando Voorn", "band_name is the label 'Native Boundaries'")
    }

    func testParseDiscoverBatch_fallsBackToBandNameWhenAlbumArtistIsNull() throws {
        let data = try fixtureJSON("bandcamp-discover-synthetic")
        let (releases, _) = BandcampClient.parseDiscoverBatch(data: data)
        let bare = try XCTUnwrap(releases.first { $0.title == "No Featured Track" })
        XCTAssertEqual(bare.artist, "Artist Name")
        XCTAssertNil(bare.featuredTrackDurationSeconds)
        XCTAssertEqual(bare.releaseURL.absoluteString, "https://artistname.bandcamp.com/album/bare-album")
    }

    func testParseDiscoverBatch_dropsResultsMissingTitleOrURL() throws {
        let data = try fixtureJSON("bandcamp-discover-synthetic")
        let (releases, cursor) = BandcampClient.parseDiscoverBatch(data: data)
        XCTAssertEqual(cursor, "SYNTHETIC_CURSOR_PAGE_1")
        // 4 results in, 2 out: an empty title and a null item_url are both
        // unusable, and a candidate with no URL cannot take the resolver's
        // direct-URL shortcut at all.
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(Set(releases.map(\.title)), ["Custom Domain Album", "No Featured Track"])
    }

    func testParseDiscoverBatch_customDomainSurvivesIntact() throws {
        let data = try fixtureJSON("bandcamp-discover-synthetic")
        let (releases, _) = BandcampClient.parseDiscoverBatch(data: data)
        let custom = try XCTUnwrap(releases.first { $0.title == "Custom Domain Album" })
        // v1 hands back a whole `item_url`, so a custom domain needs no
        // reassembly from subdomain/slug hints the way v3 did — it just
        // needs its query stripped.
        XCTAssertEqual(custom.releaseURL.absoluteString, "https://records.example/album/custom-album")
        XCTAssertEqual(custom.artist, "Signed Artist")
        XCTAssertEqual(custom.featuredTrackTitle, "Opening Statement")
    }

    func testParseDiscoverBatch_malformedJSON_returnsEmpty() {
        let garbage = Data("not json".utf8)
        let (releases, cursor) = BandcampClient.parseDiscoverBatch(data: garbage)
        XCTAssertEqual(releases.count, 0)
        XCTAssertNil(cursor)
    }

    // MARK: - The request body

    /// REGRESSION. The v3 bug was silent for exactly one reason: no test
    /// ever looked at what went out on the wire. The tag was in the URL,
    /// the response was 200, the parse succeeded, and every assertion in
    /// this file passed while the station broadcast punk on a techno
    /// preset. So the tag reaching the request is now itself an assertion.
    func testRequestBodyCarriesTheTag() throws {
        let body = try BandcampClient.requestBody(slug: "death-metal", sort: .date, cursor: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["tag_norm_names"] as? [String], ["death-metal"])
        XCTAssertEqual(json["include_result_types"] as? [String], ["a"])
        XCTAssertEqual(json["slice"] as? String, "new")
        XCTAssertNil(json["cursor"], "a present-but-null cursor is a malformed first request; the key must be absent")
    }

    func testRequestBodySortMapsToSlice() throws {
        let newest = try BandcampClient.requestBody(slug: "techno", sort: .date, cursor: nil)
        let popular = try BandcampClient.requestBody(slug: "techno", sort: .pop, cursor: nil)
        XCTAssertEqual(try slice(of: newest), "new")
        XCTAssertEqual(try slice(of: popular), "top")
    }

    func testRequestBodyIncludesCursorOnLaterPages() throws {
        let body = try BandcampClient.requestBody(slug: "techno", sort: .date, cursor: "OPAQUE==")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["cursor"] as? String, "OPAQUE==")
    }

    /// The end-to-end version of the regression above: drive the real
    /// ``BandcampClient/releases(forTag:sort:maxPages:)`` through a stubbed
    /// URLProtocol and read the bytes it actually POSTed.
    func testReleasesPOSTsTheTagToTheDiscoverEndpoint() async throws {
        let recorder = BandcampStubRecorder()
        BandcampStubURLProtocol.recorder = recorder
        BandcampStubURLProtocol.responder = { _ in try fixtureData("bandcamp-discover-synthetic") }
        defer { BandcampStubURLProtocol.reset() }

        let client = BandcampClient(userAgent: "Ratbat/test", session: Self.stubbedSession())
        // maxPages 1: the synthetic fixture's cursor never advances, and
        // one page is all this assertion needs.
        let releases = try await client.releases(forTag: "Death Metal", sort: .pop, maxPages: 1)
        XCTAssertEqual(releases.count, 2)

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://bandcamp.com/api/discover/1/discover_web")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(sent.headers["User-Agent"], "Ratbat/test", "the client's UA posture must survive the endpoint change")
        XCTAssertEqual(sent.headers["Accept"], "application/json")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.body)) as? [String: Any])
        XCTAssertEqual(
            json["tag_norm_names"] as? [String], ["death-metal"],
            "the tag must reach the wire, normalised — this is the assertion whose absence hid the v3 bug"
        )
        XCTAssertEqual(json["slice"] as? String, "top")
    }

    /// Paging stops when the cursor stops moving. The synthetic fixture
    /// returns the same cursor every time, which is precisely the shape
    /// that would otherwise spin until `maxPages`.
    func testReleasesStopsWhenTheCursorDoesNotAdvance() async throws {
        let recorder = BandcampStubRecorder()
        BandcampStubURLProtocol.recorder = recorder
        BandcampStubURLProtocol.responder = { _ in try fixtureData("bandcamp-discover-synthetic") }
        defer { BandcampStubURLProtocol.reset() }

        let client = BandcampClient(userAgent: "Ratbat/test", session: Self.stubbedSession())
        let releases = try await client.releases(forTag: "techno", maxPages: 5)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2, "one request, then one more that returns the same cursor, then stop")
        XCTAssertEqual(releases.count, 4, "both batches are kept; only the paging stops")
    }

    /// Bandcamp reports a rejected request shape as HTTP 200 with an
    /// exception envelope. Treating that as an empty page is the same
    /// silent-wrong-answer failure mode the v3 endpoint had.
    func testExceptionEnvelopeIsNotMistakenForAnEmptyPage() async throws {
        let recorder = BandcampStubRecorder()
        BandcampStubURLProtocol.recorder = recorder
        BandcampStubURLProtocol.responder = { _ in
            Data(#"{"__api_special__":"exception","error_type":"Discover_1::DiscoverWebException"}"#.utf8)
        }
        defer { BandcampStubURLProtocol.reset() }

        let client = BandcampClient(userAgent: "Ratbat/test", session: Self.stubbedSession())
        let releases = try await client.releases(forTag: "techno", maxPages: 3)
        XCTAssertTrue(releases.isEmpty)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1, "the throw breaks the page loop instead of retrying into the same error")
    }

    // MARK: - Helpers

    private static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BandcampStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func slice(of body: Data) throws -> String {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["slice"] as? String)
    }

    private func fixtureJSON(_ name: String) throws -> Data {
        try Self.loadFixture(name, in: Bundle(for: type(of: self)))
    }

    fileprivate static func loadFixture(_ name: String, in bundle: Bundle) throws -> Data {
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        guard let url else { throw XCTSkip("Fixture \(name).json missing") }
        return try Data(contentsOf: url)
    }
}

// MARK: - URLProtocol stub

/// One recorded outbound request. `URLRequest.httpBody` is nil by the time
/// `URLProtocol` sees it — the body has already been swapped for a
/// `httpBodyStream` — so the stream is drained here and the bytes kept.
private struct BandcampRecordedRequest: Sendable {
    let method: String?
    let url: URL?
    let headers: [String: String]
    let body: Data?
}

private actor BandcampStubRecorder {
    private(set) var requests: [BandcampRecordedRequest] = []
    func append(_ request: BandcampRecordedRequest) { requests.append(request) }
}

private final class BandcampStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: BandcampStubRecorder?
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) throws -> Data)?

    static func reset() {
        recorder = nil
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let recorded = BandcampRecordedRequest(
            method: request.httpMethod,
            url: request.url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.drainBody(of: request)
        )
        if let recorder = Self.recorder {
            // Fire-and-forget onto the recorder actor, then wait for it —
            // the assertion reads this list after the client returns, so
            // the append must be ordered before the response completes.
            let done = DispatchSemaphore(value: 0)
            Task {
                await recorder.append(recorded)
                done.signal()
            }
            done.wait()
        }

        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let data = try responder(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://bandcamp.com/")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drainBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Free function so the `@Sendable` responder closures above don't capture
/// `self` just to reach a fixture.
private func fixtureData(_ name: String) throws -> Data {
    try BandcampClientTests.loadFixture(name, in: Bundle(for: BandcampClientTests.self))
}
#endif
