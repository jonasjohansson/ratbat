#if os(macOS)
import Foundation
import OSLog

/// Scrapes NTS Radio for shows + tracklists.
///
/// NTS publishes weekly DJ shows with public tracklists. We use those
/// tracklists as the curation layer for generative stations — the DJs
/// pick what plays next, Ratbat just plays it.
///
/// ## Transport
///
/// The nts.live website is a client-rendered SPA — the HTML shell carries
/// no useful data and genre/tag landing pages don't exist as server-rendered
/// routes. NTS does expose a public JSON API at `/api/v2/` (the same one
/// the web player talks to), which is dramatically more stable than scraping
/// React markup. This client talks to that API directly:
///
/// - `GET /api/v2/shows` — paginated show directory, each entry has
///   `show_alias`, `name`, `genres`, `moods`, `location_*`, and a `links`
///   array with `self` + `episodes` URLs. We filter by genre value client-side
///   (the server's `?genres=` query parameter is not reliably honored).
/// - `GET /api/v2/shows/<alias>/episodes` — episodes for a show, with
///   `episode_alias`, `broadcast` (ISO 8601), and a `links[rel=tracklist]`.
/// - `GET /api/v2/shows/<alias>/episodes/<ep>/tracklist` — the actual
///   tracklist as `{artist, title, uid, offset, duration}` rows.
///
/// ## Design notes
///
/// - Stateless + rate-limit-friendly: 6h in-memory cache per URL, minimum
///   1s gap between fetches enforced by the actor.
/// - Fails gracefully when NTS changes shapes — missing fields default to
///   `nil`, malformed JSON raises ``Error/malformed(_:reason:)``.
/// - Swift 6 strict concurrency: actor-isolated mutable state, `Sendable`
///   value types, no `@MainActor` — this is a background service.
public actor NTSClient {
    public struct Show: Identifiable, Sendable, Hashable {
        public let id: String           // show_alias — stable slug
        public let url: URL             // https://www.nts.live/shows/<alias>
        public let title: String        // show name
        public let host: String?        // DJ / host if derivable from title
        public let publishedAt: Date?   // last `updated` timestamp if parseable
        public let tags: [String]       // genre values (e.g. "Ambient", "Techno")
    }

    public struct Tracklisting: Sendable, Hashable {
        public let artist: String
        public let title: String
        public let showURL: URL
        public let position: Int        // 1-based order in the show
    }

    public enum Error: Swift.Error, Sendable, Equatable {
        case fetchFailed(URL, String)   // underlying error flattened to String for Equatable
        case malformed(URL, reason: String)
        case rateLimited

        public static func == (lhs: Error, rhs: Error) -> Bool {
            switch (lhs, rhs) {
            case (.rateLimited, .rateLimited): return true
            case let (.fetchFailed(u1, m1), .fetchFailed(u2, m2)):
                return u1 == u2 && m1 == m2
            case let (.malformed(u1, r1), .malformed(u2, r2)):
                return u1 == u2 && r1 == r2
            default: return false
            }
        }
    }

    // MARK: - State

    private var cache: [URL: (fetchedAt: Date, data: Data)] = [:]
    private let cacheTTL: TimeInterval = 6 * 3600
    private var lastFetch: Date = .distantPast
    private let minGap: TimeInterval = 1.0
    private let session: URLSession
    private let apiBase = URL(string: "https://www.nts.live/api/v2")!
    private let siteBase = URL(string: "https://www.nts.live")!
    private let userAgent = "Ratbat/1.0 (personal radio)"
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "nts")

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Fetch shows currently matching a given tag (genre substring, case
    /// insensitive — e.g. `"ambient"` matches `"Ambient"`, `"Dark Ambient"`,
    /// `"Ambient Techno"`). Returns up to `limit` shows.
    ///
    /// The NTS shows directory holds ~1700 entries. We scan the first page
    /// only by default (up to 200 results per NTS page) which is enough to
    /// seed a genre-curated station; heavier scans are left for a future
    /// caller that wants deep lookup.
    public func shows(forTag tag: String, limit: Int = 20) async throws -> [Show] {
        let url = apiBase.appendingPathComponent("shows")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "200")])
        let data = try await fetch(url)
        return try parseShows(from: data, tag: tag, sourceURL: url).prefix(limit).map { $0 }
    }

    /// Fetch the full tracklist for a given show URL.
    ///
    /// Accepts either an episode URL — `/shows/<alias>/episodes/<ep>` — or a
    /// show URL — `/shows/<alias>` — in which case the most recent episode's
    /// tracklist is returned.
    ///
    /// Returns an empty array for shows that haven't published a tracklist yet
    /// (common for live-but-not-yet-archived broadcasts) — this is not an
    /// error state.
    public func tracklist(for showURL: URL) async throws -> [Tracklisting] {
        let (alias, episode) = try splitShowURL(showURL)
        let episodeAlias: String
        if let episode {
            episodeAlias = episode
        } else {
            episodeAlias = try await latestEpisodeAlias(showAlias: alias)
        }
        let url = apiBase
            .appendingPathComponent("shows")
            .appendingPathComponent(alias)
            .appendingPathComponent("episodes")
            .appendingPathComponent(episodeAlias)
            .appendingPathComponent("tracklist")
        let data = try await fetch(url)
        return try parseTracklist(from: data, showURL: showURL)
    }

    // MARK: - Internal (exposed for @testable import)

    /// Parse the `/api/v2/shows` response. Filters results by tag substring
    /// (case-insensitive match against each show's `genres[].value`).
    internal func parseShows(from data: Data, tag: String, sourceURL: URL) throws -> [Show] {
        let needle = tag.lowercased()
        let envelope: ShowsEnvelope
        do {
            envelope = try decoder.decode(ShowsEnvelope.self, from: data)
        } catch {
            throw Error.malformed(sourceURL, reason: "shows envelope: \(error)")
        }
        return envelope.results.compactMap { raw -> Show? in
            let genreValues = (raw.genres ?? []).map { $0.value }
            guard genreValues.contains(where: { $0.lowercased().contains(needle) }) else {
                return nil
            }
            let title = normalize(raw.name ?? "")
            guard !title.isEmpty else { return nil }
            let showURL = siteBase.appendingPathComponent("shows").appendingPathComponent(raw.show_alias)
            return Show(
                id: raw.show_alias,
                url: showURL,
                title: title,
                host: extractHost(from: title),
                publishedAt: parseISO8601(raw.updated),
                tags: genreValues
            )
        }
    }

    /// Parse `/api/v2/shows/<alias>/episodes/<ep>/tracklist` into
    /// 1-based-ordered ``Tracklisting`` values.
    internal func parseTracklist(from data: Data, showURL: URL) throws -> [Tracklisting] {
        let envelope: TracklistEnvelope
        do {
            envelope = try decoder.decode(TracklistEnvelope.self, from: data)
        } catch {
            throw Error.malformed(showURL, reason: "tracklist envelope: \(error)")
        }
        var out: [Tracklisting] = []
        out.reserveCapacity(envelope.results.count)
        for (idx, row) in envelope.results.enumerated() {
            let artist = normalize(row.artist ?? "")
            let title = normalize(row.title ?? "")
            guard !artist.isEmpty, !title.isEmpty else { continue }
            out.append(Tracklisting(
                artist: artist,
                title: title,
                showURL: showURL,
                position: idx + 1
            ))
        }
        // Re-number to guarantee contiguous 1..n if any rows were skipped.
        return out.enumerated().map { offset, t in
            Tracklisting(artist: t.artist, title: t.title, showURL: t.showURL, position: offset + 1)
        }
    }

    /// Parse the `/api/v2/shows/<alias>/episodes` response into episode
    /// aliases, newest first. Exposed `internal` so tests can cover it if
    /// needed; currently only consumed by ``latestEpisodeAlias(showAlias:)``.
    internal func parseEpisodeAliases(from data: Data, sourceURL: URL) throws -> [String] {
        let envelope: EpisodesEnvelope
        do {
            envelope = try decoder.decode(EpisodesEnvelope.self, from: data)
        } catch {
            throw Error.malformed(sourceURL, reason: "episodes envelope: \(error)")
        }
        return envelope.results.map(\.episode_alias)
    }

    // MARK: - Internals

    private func latestEpisodeAlias(showAlias: String) async throws -> String {
        let url = apiBase
            .appendingPathComponent("shows")
            .appendingPathComponent(showAlias)
            .appendingPathComponent("episodes")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "1")])
        let data = try await fetch(url)
        let aliases = try parseEpisodeAliases(from: data, sourceURL: url)
        guard let first = aliases.first else {
            throw Error.malformed(url, reason: "show has no episodes")
        }
        return first
    }

    /// Splits a user-supplied NTS URL into `(showAlias, episodeAlias?)`.
    /// Accepts absolute URLs; path must start with `/shows/<alias>` and
    /// optionally continue `/episodes/<ep>`.
    private func splitShowURL(_ url: URL) throws -> (show: String, episode: String?) {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "shows" else {
            throw Error.malformed(url, reason: "not an NTS show URL")
        }
        let show = parts[1]
        if parts.count >= 4, parts[2] == "episodes" {
            return (show, parts[3])
        }
        return (show, nil)
    }

    /// Fetches `url` with caching, rate limiting, and a friendly UA. Raw
    /// bytes are returned so callers decide how to decode.
    private func fetchHTML(_ url: URL) async throws -> String {
        let data = try await fetch(url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.malformed(url, reason: "not UTF-8")
        }
        return s
    }

    private func fetch(_ url: URL) async throws -> Data {
        // Cache hit.
        if let hit = cache[url], Date().timeIntervalSince(hit.fetchedAt) < cacheTTL {
            return hit.data
        }
        // Rate limit.
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
        logger.debug("NTS fetched \(url.absoluteString, privacy: .public) (\(data.count) bytes)")
        return data
    }

    // MARK: - Helpers

    private func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse runs of whitespace to single spaces, preserve punctuation.
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

    /// If the title looks like `"Show Name w/ DJ Host"`, pull the host.
    private func extractHost(from title: String) -> String? {
        // NTS convention: " w/ " separates show from host.
        if let range = title.range(of: " w/ ") {
            let host = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return host.isEmpty ? nil : String(host)
        }
        return nil
    }

    private func parseISO8601(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        return d
    }

    // MARK: - API DTOs

    // Snake-case matches the NTS API exactly — easier to read against the
    // live JSON than rewriting a CodingKeys map. The fields we don't use
    // (media, external_links, moods, intensity, brand, embeds) are omitted.

    private struct ShowsEnvelope: Decodable {
        let results: [ShowRaw]
    }

    private struct ShowRaw: Decodable {
        let show_alias: String
        let name: String?
        let updated: String?
        let genres: [GenreRaw]?
    }

    private struct GenreRaw: Decodable {
        let id: String
        let value: String
    }

    private struct EpisodesEnvelope: Decodable {
        let results: [EpisodeRaw]
    }

    private struct EpisodeRaw: Decodable {
        let episode_alias: String
    }

    private struct TracklistEnvelope: Decodable {
        let results: [TrackRaw]
    }

    private struct TrackRaw: Decodable {
        let artist: String?
        let title: String?
    }
}

// Foundation's URL `appending(queryItems:)` is iOS 16 / macOS 13+, which this
// project targets (macOS 14 / iOS 17). No polyfill required.
#endif
