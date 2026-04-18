#if os(macOS)
import Foundation
import OSLog

/// Read-only client for the Last.fm REST API.
///
/// Ratbat uses Last.fm as a generative curation source: given a tag the
/// user is interested in (e.g. "techno"), we pull `tag.getTopTracks` and
/// feed the (artist, title) pairs into ``TrackResolver`` just like the
/// NTS source does with DJ tracklists. No scrobbling, no user auth —
/// everything we need lives behind a single free API key.
///
/// ## API shape
/// - Base: `https://ws.audioscrobbler.com/2.0/`
/// - All endpoints: `GET /?method=tag.getTopTracks&tag=X&limit=100&page=1&api_key=…&format=json`
/// - JSON envelope: `{ tracks: { track: [{ name, artist: { name }, … }], @attr: { page, total, ... } } }`
///
/// ## Design
/// - Stateless + rate-limit-friendly: 6h in-memory cache per URL, minimum
///   250ms gap between fetches (Last.fm publishes 5 req/s as their limit;
///   we stay well under out of politeness).
/// - Fails softly on malformed JSON — the envelope check returns nil and
///   callers fall through to the next tag or page.
public actor LastFMClient {
    public struct TrackCandidate: Sendable, Hashable {
        public let artist: String
        public let title: String
        public let listeners: Int     // popularity ~ global listeners
        public let playcount: Int     // total playcount

        public init(artist: String, title: String, listeners: Int, playcount: Int) {
            self.artist = artist
            self.title = title
            self.listeners = listeners
            self.playcount = playcount
        }
    }

    /// One row from `artist.getTopTags`. Last.fm returns tag name + a
    /// 0-100 relevance count; we expose both so callers can decide how
    /// strict a threshold to apply.
    public struct ArtistTag: Sendable, Hashable {
        public let name: String    // lowercased
        public let count: Int      // Last.fm 0-100 relevance weight

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public enum Error: Swift.Error, Sendable, Equatable {
        case apiKeyMissing
        case fetchFailed(URL, String)
        case malformed(URL, reason: String)
        case rateLimited
        case apiError(code: Int, message: String)
    }

    // MARK: - State

    private var cache: [URL: (fetchedAt: Date, data: Data)] = [:]
    private let cacheTTL: TimeInterval = 6 * 3600
    private var lastFetch: Date = .distantPast
    private let minGap: TimeInterval = 0.25

    /// Per-artist cache of the sorted tag list returned by
    /// `artist.getTopTags`. Keyed on lowercased artist name so the same
    /// artist isn't re-fetched whether the candidate row cased them as
    /// "Portishead" or "portishead". Lives for the process lifetime —
    /// artist tags change slowly enough that we don't bother persisting.
    private var artistTagCache: [String: [ArtistTag]] = [:]
    private let session: URLSession
    private let apiBase = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private let userAgent = "Ratbat/1.0 (personal radio)"
    private let apiKey: String
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "lastfm")

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Public API

    /// Fetch the top tracks for a given tag. Paginates until `limit`
    /// candidates are collected or the tag's result set is exhausted.
    ///
    /// Returns a list of `(artist, title)` pairs with popularity metadata.
    /// The caller is responsible for dedup / ordering / playback — this is
    /// deliberately a raw API wrapper.
    public func topTracks(forTag tag: String, limit: Int = 100) async throws -> [TrackCandidate] {
        guard !apiKey.isEmpty else { throw Error.apiKeyMissing }

        let pageSize = 100      // Last.fm max per page
        let maxPages = 5        // 500 tracks is plenty for one tag
        var collected: [TrackCandidate] = []

        for pageIndex in 1...maxPages {
            var comps = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "method", value: "tag.gettoptracks"),
                URLQueryItem(name: "tag", value: tag),
                URLQueryItem(name: "limit", value: "\(pageSize)"),
                URLQueryItem(name: "page", value: "\(pageIndex)"),
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let url = comps.url else { break }

            let data: Data
            do {
                data = try await fetch(url)
            } catch {
                logger.info("topTracks pagination stopped at page \(pageIndex): \(String(describing: error), privacy: .public)")
                break
            }

            let page = try parseTopTracks(from: data, sourceURL: url)
            if page.isEmpty { break }   // tag has no more results
            collected.append(contentsOf: page)
            if collected.count >= limit { break }
        }

        logger.info("topTracks(tag: \(tag, privacy: .public)) fetched \(collected.count) track(s)")
        return Array(collected.prefix(limit))
    }

    /// Fetch the top-tags list for an artist, sorted by Last.fm's own
    /// relevance count (descending). Cached per-actor so repeated calls
    /// for the same artist are free after the first.
    ///
    /// Used by the `LastFMPrecisionMode` filter to verify that a candidate
    /// actually belongs to the requested genre — drops mis-tagged tracks
    /// (e.g. eurodance tracks leaking into a "techno" pool) before they
    /// reach the encoder.
    public func artistTopTags(_ artist: String) async throws -> [ArtistTag] {
        guard !apiKey.isEmpty else { throw Error.apiKeyMissing }
        let cacheKey = artist
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let hit = artistTagCache[cacheKey] { return hit }

        var comps = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "artist.gettoptags"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { return [] }

        let data = try await fetch(url)
        let tags = try parseArtistTopTags(from: data, sourceURL: url)
        artistTagCache[cacheKey] = tags
        return tags
    }

    // MARK: - Internal (exposed for @testable import)

    /// Parse a `tag.gettoptracks` response into ``TrackCandidate`` values.
    /// Skips entries with missing artist/title — they'd be useless to
    /// feed into the resolver.
    internal func parseTopTracks(from data: Data, sourceURL: URL) throws -> [TrackCandidate] {
        // Last.fm wraps API errors in a `{ error: <code>, message: "…" }`
        // shape with 200 OK — decode that first before attempting success
        // envelope parsing so real errors surface with their message.
        if let errorEnvelope = try? JSONDecoder().decode(ApiError.self, from: data), errorEnvelope.error != 0 {
            throw Error.apiError(code: errorEnvelope.error, message: errorEnvelope.message ?? "")
        }

        let envelope: TopTracksEnvelope
        do {
            envelope = try JSONDecoder().decode(TopTracksEnvelope.self, from: data)
        } catch {
            throw Error.malformed(sourceURL, reason: "top tracks envelope: \(error)")
        }

        return (envelope.tracks?.track ?? []).compactMap { raw -> TrackCandidate? in
            let title = normalize(raw.name ?? "")
            let artistName = normalize(raw.artist?.name ?? "")
            guard !title.isEmpty, !artistName.isEmpty else { return nil }
            return TrackCandidate(
                artist: artistName,
                title: title,
                listeners: Int(raw.listeners ?? "0") ?? 0,
                playcount: Int(raw.playcount ?? "0") ?? 0
            )
        }
    }

    /// Parse an `artist.gettoptags` response. Returns tags lowercased and
    /// sorted by the Last.fm-supplied relevance `count` (descending), so
    /// callers that only care about the top-N tags can just `prefix(N)`.
    internal func parseArtistTopTags(from data: Data, sourceURL: URL) throws -> [ArtistTag] {
        if let errorEnvelope = try? JSONDecoder().decode(ApiError.self, from: data), errorEnvelope.error != 0 {
            throw Error.apiError(code: errorEnvelope.error, message: errorEnvelope.message ?? "")
        }
        let envelope: ArtistTopTagsEnvelope
        do {
            envelope = try JSONDecoder().decode(ArtistTopTagsEnvelope.self, from: data)
        } catch {
            throw Error.malformed(sourceURL, reason: "artist top tags envelope: \(error)")
        }
        let rows = (envelope.toptags?.tag ?? []).compactMap { raw -> ArtistTag? in
            guard let name = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let count: Int
            if let n = raw.count { count = n }
            else { count = 0 }
            return ArtistTag(name: name.lowercased(), count: count)
        }
        return rows.sorted { $0.count > $1.count }
    }

    // MARK: - Internals

    /// Fetches `url` with caching + rate limiting + friendly UA.
    private func fetch(_ url: URL) async throws -> Data {
        if let hit = cache[url], Date().timeIntervalSince(hit.fetchedAt) < cacheTTL {
            return hit.data
        }
        let now = Date()
        let gap = now.timeIntervalSince(lastFetch)
        if gap < minGap {
            let sleepNanos = UInt64((minGap - gap) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNanos)
        }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Error.fetchFailed(url, "\(error)")
        }
        lastFetch = Date()
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw Error.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                throw Error.fetchFailed(url, "HTTP \(http.statusCode)")
            }
        }
        cache[url] = (fetchedAt: Date(), data: data)
        logger.debug("Last.fm fetched \(url.absoluteString, privacy: .public) (\(data.count) bytes)")
        return data
    }

    /// Collapse runs of whitespace + trim. Matches the NTS client's
    /// normalization so history-dedup keys line up across both sources
    /// (same artist/title normalized the same way).
    private func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        out.reserveCapacity(trimmed.count)
        var prevSpace = false
        for c in trimmed {
            if c.isWhitespace {
                if !prevSpace { out.append(" ") }
                prevSpace = true
            } else {
                out.append(c)
                prevSpace = false
            }
        }
        return out
    }

    // MARK: - DTOs

    // Last.fm tolerates a fair amount of shape variation — fields ride
    // along as optionals so a missing `playcount` or an empty tracklist
    // don't blow up the decode.

    private struct ApiError: Decodable {
        let error: Int
        let message: String?
    }

    private struct TopTracksEnvelope: Decodable {
        let tracks: TopTracksBody?
    }

    private struct TopTracksBody: Decodable {
        let track: [TrackRaw]?
    }

    private struct TrackRaw: Decodable {
        let name: String?
        let artist: ArtistRef?
        let listeners: String?   // Last.fm returns these as strings, annoyingly
        let playcount: String?
    }

    private struct ArtistRef: Decodable {
        let name: String?
    }

    private struct ArtistTopTagsEnvelope: Decodable {
        let toptags: ArtistTopTagsBody?
    }

    private struct ArtistTopTagsBody: Decodable {
        let tag: [ArtistTagRaw]?
    }

    private struct ArtistTagRaw: Decodable {
        let name: String?
        let count: Int?
    }
}
#endif
