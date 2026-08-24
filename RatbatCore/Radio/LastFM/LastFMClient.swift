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

    /// One artist as `artist.getinfo` describes them — the "about this
    /// artist" facts `/trackinfo` serves. `bio` is already plain text by
    /// the time it lands here: tags stripped, Last.fm's trailing "Read
    /// more" boilerplate removed, capped at a sentence boundary (see
    /// ``plainBio(_:)``), so no caller ever has to sanitize HTML.
    public struct ArtistInfo: Sendable, Hashable {
        /// True when Last.fm's biography is describing SEVERAL artists who
        /// merely share this name, not the one that is playing.
        ///
        /// Last.fm keys artists by name, so a Japanese algorithmic composer
        /// called "uro" collects the biography, tags, listener count and
        /// neighbours of a Danish anarcho-punk band of the same name. The
        /// wire drops the whole record when this is set: nothing in it can
        /// be attributed to the artist on air, and confidently wrong facts
        /// are worse than none.
        public var isAmbiguous: Bool { Self.readsAsDisambiguation(bio) }

        /// Last.fm writes these entries in two house styles: an explicit
        /// preamble, or a bare enumeration of the acts that share the name.
        ///
        /// The enumeration is hand-typed by whoever edited the page, so its
        /// punctuation is whatever they felt like — "1)", "1 )", "1.", "1
        /// -". A Bandcamp producer called FAFA was handed an Indonesian
        /// rapper and a Connecticut punk band merged into one biography
        /// because the check tested for "1)" and the page began "1 )".
        /// Strip the spaces before looking, and read past the marker: a
        /// leading "1" only means a list if a "2" follows it.
        static func readsAsDisambiguation(_ bio: String?) -> Bool {
            guard let bio else { return false }
            let head = String(bio.prefix(400)).lowercased()
            // The preambles, in the wordings Last.fm's editors actually
            // use. "there are at least 7 bands called Horns" is one of
            // them, and it matched none of the phrases this list started
            // with — which is how a disco track came to be described as
            // Chilean raw black metal.
            let preambles = [
                "more than one artist", "multiple artists", "may refer to",
                "several artists", "bands called", "artists called",
                "artists named", "artists with this name", "bands with this name",
                "bands named", "at least",
            ]
            if preambles.contains(where: { head.contains($0) }) { return true }

            // Whitespace is the part the editors disagree about, so it is
            // the part to discard before matching.
            let squeezed = head.filter { !$0.isWhitespace }

            // A parenthesised enumeration ANYWHERE in the opening is the
            // giveaway, not just one that starts the biography: the list
            // often follows a sentence of preamble, and requiring it at
            // the front is what let the "Horns" entry through.
            if squeezed.contains("1)") && squeezed.contains("2)") { return true }

            // The other punctuations are weaker — a discography can be
            // numbered "1." — so for those, keep requiring the list to
            // open the biography.
            let opens = ["1.", "1-", "1:"]
            let follows = ["2.", "2-", "2:"]
            guard opens.contains(where: { squeezed.hasPrefix($0) }) else { return false }
            // A biography that enumerates artists always reaches a second
            // one. Requiring it keeps a real bio from being thrown away.
            return follows.contains(where: { squeezed.contains($0) })
        }

        public let bio: String?
        public let listeners: Int?
        public let playcount: Int?
        public let tags: [String]      // lowercased, Last.fm's order
        public let similar: [String]

        public init(bio: String?, listeners: Int?, playcount: Int?, tags: [String], similar: [String]) {
            self.bio = bio
            self.listeners = listeners
            self.playcount = playcount
            self.tags = tags
            self.similar = similar
        }
    }

    /// One recording as `track.getinfo` describes it. `wiki` gets the
    /// same plain-text treatment as ``ArtistInfo/bio``.
    public struct TrackInfo: Sendable, Hashable {
        public let album: String?
        public let listeners: Int?
        public let playcount: Int?
        public let tags: [String]      // lowercased, Last.fm's order
        public let wiki: String?

        public init(album: String?, listeners: Int?, playcount: Int?, tags: [String], wiki: String?) {
            self.album = album
            self.listeners = listeners
            self.playcount = playcount
            self.tags = tags
            self.wiki = wiki
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
    /// Per-artist cache of `artist.getSimilar` results (lowercased seed →
    /// ordered similar-artist names). Same rationale as `artistTagCache`:
    /// similarity graphs move slowly, so a process-lifetime cache is plenty.
    private var similarArtistCache: [String: [String]] = [:]
    /// `/trackinfo` enrichment caches, keyed lowercased artist and
    /// lowercased artist|title. Unlike the tag/similar caches above these
    /// carry a TTL: listener and playcount figures move daily, so 24h
    /// keeps them honest without hammering the API on every poll. The
    /// in-flight maps give each key single-flight semantics — N clients
    /// asking about the same current track at once share ONE upstream
    /// fetch instead of racing N (the URL cache below can't do this: it
    /// only fills after a fetch completes).
    private var artistInfoCache: [String: (fetchedAt: Date, info: ArtistInfo)] = [:]
    private var trackInfoCache: [String: (fetchedAt: Date, info: TrackInfo)] = [:]
    private var artistInfoInFlight: [String: Task<ArtistInfo, Swift.Error>] = [:]
    private var trackInfoInFlight: [String: Task<TrackInfo, Swift.Error>] = [:]
    private let infoCacheTTL: TimeInterval = 24 * 3600
    private let session: URLSession
    private let apiBase = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private let userAgent = "Ratbat/1.0 (personal radio)"
    private let apiKey: String
    private let logger = Logger(subsystem: RatbatLog.subsystem, category: "lastfm")

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
    /// Used by the precision-verification stage to check that a candidate
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

    /// Artists Last.fm considers similar to `artist`, strongest match
    /// first. Powers similar-artist discovery: given the artists a user
    /// most engages with on a station, we pull their neighbours and feed
    /// those neighbours' top tracks into the pool. Cached per-artist.
    public func similarArtists(to artist: String, limit: Int = 10) async throws -> [String] {
        guard !apiKey.isEmpty else { throw Error.apiKeyMissing }
        let cacheKey = artist
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let hit = similarArtistCache[cacheKey] { return Array(hit.prefix(limit)) }

        var comps = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "artist.getsimilar"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "limit", value: "\(max(limit, 1))"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { return [] }

        let data = try await fetch(url)
        let names = try parseSimilarArtists(from: data, sourceURL: url)
        similarArtistCache[cacheKey] = names
        return Array(names.prefix(limit))
    }

    /// Top tracks for a single artist (`artist.getTopTracks`). Used to turn
    /// a similar-artist name into playable `(artist, title)` candidates.
    /// Unlike ``topTracks(forTag:limit:)`` this is a single page — a
    /// handful of an artist's biggest tracks is all the pool needs.
    public func topTracksForArtist(_ artist: String, limit: Int = 5) async throws -> [TrackCandidate] {
        guard !apiKey.isEmpty else { throw Error.apiKeyMissing }
        var comps = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "artist.gettoptracks"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "limit", value: "\(max(limit, 1))"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { return [] }
        let data = try await fetch(url)
        return try parseArtistTopTracks(from: data, sourceURL: url)
    }

    /// "About this artist" (`artist.getinfo`): bio, global stats, top
    /// tags, similar artists. Powers the `/trackinfo` endpoint, whose
    /// callers poll — hence the 24h TTL and the single-flight coalescing
    /// (see the cache comment above). Failures are thrown, not cached:
    /// a transient outage deserves a retry on the next request, exactly
    /// the ``MusicBrainzClient`` stance.
    public func artistInfo(_ artist: String) async throws -> ArtistInfo {
        guard !apiKey.isEmpty else { throw Error.apiKeyMissing }
        let cacheKey = artist
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let hit = artistInfoCache[cacheKey],
           Date().timeIntervalSince(hit.fetchedAt) < infoCacheTTL {
            return hit.info
        }
        if let inFlight = artistInfoInFlight[cacheKey] {
            return try await inFlight.value
        }
        // Registering the task BEFORE the first await is what makes this
        // single-flight: any caller arriving during the fetch finds the
        // task above and awaits it, so one URL hits the wire per key.
        let task = Task { try await self.fetchArtistInfo(artist) }
        artistInfoInFlight[cacheKey] = task
        defer { artistInfoInFlight[cacheKey] = nil }
        let info = try await task.value
        artistInfoCache[cacheKey] = (fetchedAt: Date(), info: info)
        return info
    }

    /// "About this track" (`track.getinfo`): album, stats, top tags,
    /// wiki blurb. Same caching contract as ``artistInfo(_:)``.
    public func trackInfo(artist: String, title: String) async throws -> TrackInfo {
        guard !apiKey.isEmpty else { throw Error.apiKeyMissing }
        let cacheKey = artist
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            + "\u{1}"
            + title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hit = trackInfoCache[cacheKey],
           Date().timeIntervalSince(hit.fetchedAt) < infoCacheTTL {
            return hit.info
        }
        if let inFlight = trackInfoInFlight[cacheKey] {
            return try await inFlight.value
        }
        let task = Task { try await self.fetchTrackInfo(artist: artist, title: title) }
        trackInfoInFlight[cacheKey] = task
        defer { trackInfoInFlight[cacheKey] = nil }
        let info = try await task.value
        trackInfoCache[cacheKey] = (fetchedAt: Date(), info: info)
        return info
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

    /// Parse an `artist.getSimilar` response into ordered artist names.
    /// Last.fm returns them pre-sorted by `match` descending; we preserve
    /// that order and just drop blank names.
    internal func parseSimilarArtists(from data: Data, sourceURL: URL) throws -> [String] {
        if let errorEnvelope = try? JSONDecoder().decode(ApiError.self, from: data), errorEnvelope.error != 0 {
            throw Error.apiError(code: errorEnvelope.error, message: errorEnvelope.message ?? "")
        }
        let envelope: SimilarArtistsEnvelope
        do {
            envelope = try JSONDecoder().decode(SimilarArtistsEnvelope.self, from: data)
        } catch {
            throw Error.malformed(sourceURL, reason: "similar artists envelope: \(error)")
        }
        return (envelope.similarartists?.artist ?? []).compactMap { raw in
            let name = (raw.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
    }

    /// Parse an `artist.getTopTracks` response into ``TrackCandidate``s.
    /// Same per-row shape as `tag.getTopTracks`, so it reuses ``TrackRaw``;
    /// the artist name rides in the row's `artist.name`.
    internal func parseArtistTopTracks(from data: Data, sourceURL: URL) throws -> [TrackCandidate] {
        if let errorEnvelope = try? JSONDecoder().decode(ApiError.self, from: data), errorEnvelope.error != 0 {
            throw Error.apiError(code: errorEnvelope.error, message: errorEnvelope.message ?? "")
        }
        let envelope: ArtistTopTracksEnvelope
        do {
            envelope = try JSONDecoder().decode(ArtistTopTracksEnvelope.self, from: data)
        } catch {
            throw Error.malformed(sourceURL, reason: "artist top tracks envelope: \(error)")
        }
        return (envelope.toptracks?.track ?? []).compactMap { raw -> TrackCandidate? in
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

    /// Parse an `artist.getinfo` response into ``ArtistInfo``. Tags come
    /// back lowercased (the ``parseArtistTopTags(from:sourceURL:)`` rule,
    /// so genre strings compare the same everywhere); similar-artist
    /// names keep their casing — they're display text, and titlecase is
    /// part of the name. Bio prefers `content` over `summary` (fuller),
    /// falling back when content is blank.
    internal func parseArtistInfo(from data: Data, sourceURL: URL) throws -> ArtistInfo {
        if let errorEnvelope = try? JSONDecoder().decode(ApiError.self, from: data), errorEnvelope.error != 0 {
            throw Error.apiError(code: errorEnvelope.error, message: errorEnvelope.message ?? "")
        }
        let envelope: ArtistInfoEnvelope
        do {
            envelope = try JSONDecoder().decode(ArtistInfoEnvelope.self, from: data)
        } catch {
            throw Error.malformed(sourceURL, reason: "artist info envelope: \(error)")
        }
        let raw = envelope.artist
        let rawBio = [raw?.bio?.content, raw?.bio?.summary]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return ArtistInfo(
            bio: Self.plainBio(rawBio),
            listeners: (raw?.stats?.listeners).flatMap { Int($0) },
            playcount: (raw?.stats?.playcount).flatMap { Int($0) },
            tags: Self.cleanTagNames(raw?.tags?.tag),
            similar: (raw?.similar?.artist ?? []).compactMap {
                let name = ($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
        )
    }

    /// Parse a `track.getinfo` response into ``TrackInfo``. Same rules as
    /// ``parseArtistInfo(from:sourceURL:)`` — the wiki blurb goes through
    /// the same stripping/cap, tags are lowercased, and the numeric
    /// strings Last.fm insists on become honest Ints or nil.
    internal func parseTrackInfo(from data: Data, sourceURL: URL) throws -> TrackInfo {
        if let errorEnvelope = try? JSONDecoder().decode(ApiError.self, from: data), errorEnvelope.error != 0 {
            throw Error.apiError(code: errorEnvelope.error, message: errorEnvelope.message ?? "")
        }
        let envelope: TrackInfoEnvelope
        do {
            envelope = try JSONDecoder().decode(TrackInfoEnvelope.self, from: data)
        } catch {
            throw Error.malformed(sourceURL, reason: "track info envelope: \(error)")
        }
        let raw = envelope.track
        let rawWiki = [raw?.wiki?.content, raw?.wiki?.summary]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let album = (raw?.album?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return TrackInfo(
            album: album.isEmpty ? nil : album,
            listeners: (raw?.listeners).flatMap { Int($0) },
            playcount: (raw?.playcount).flatMap { Int($0) },
            tags: Self.cleanTagNames(raw?.toptags?.tag),
            wiki: Self.plainBio(rawWiki)
        )
    }

    /// Where the bio/wiki cap sits. "~1200": generous enough for a few
    /// real paragraphs, small enough that `/trackinfo` stays a card, not
    /// a page.
    nonisolated internal static let bioCharacterCap = 1200

    /// Reduce a Last.fm `bio`/`wiki` blob to plain text a client can
    /// render directly. Last.fm returns HTML — anchors, the occasional
    /// entity — always ending in an `<a>Read more on Last.fm</a>` link,
    /// with a Creative Commons license sentence after it in the `content`
    /// variant. None of that belongs in an "about this track" card.
    ///
    /// Tag-stripping is a linear scan, not a parser: the input is
    /// Last.fm's own constrained markup, not arbitrary HTML. Tags go
    /// first so the read-more cut only has to find the visible text,
    /// wherever the anchor markup drifts. The cap cuts at the last
    /// sentence end inside ``bioCharacterCap`` so the text never stops
    /// mid-word; a cap-length run-on with no sentence ends keeps the
    /// hard cut rather than vanishing entirely.
    nonisolated internal static func plainBio(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = ""
        text.reserveCapacity(raw.count)
        var insideTag = false
        for ch in raw {
            if ch == "<" { insideTag = true; continue }
            if ch == ">" { insideTag = false; continue }
            if !insideTag { text.append(ch) }
        }
        // Minimal entity decode — the handful Last.fm actually emits.
        // &amp; last, so "&amp;lt;" can't double-decode into a stray "<".
        for (entity, plain) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")
        ] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        // Everything from "Read more on Last.fm" onward is boilerplate:
        // the link text itself, then the license sentence.
        if let readMore = text.range(of: "Read more on Last.fm") {
            text = String(text[..<readMore.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > bioCharacterCap {
            let head = String(text.prefix(bioCharacterCap))
            if let cut = head.lastIndex(where: { ".!?".contains($0) }) {
                text = String(head[...cut])
            } else {
                text = head
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    /// Shared tag cleanup for the two info parsers: drop blanks,
    /// lowercase, keep Last.fm's own relevance order.
    nonisolated private static func cleanTagNames(_ rows: [ArtistTagRaw]?) -> [String] {
        (rows ?? []).compactMap { row in
            let name = (row.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name.lowercased()
        }
    }

    // MARK: - Internals

    /// Fetch + parse behind ``artistInfo(_:)`` — split out so the
    /// single-flight task wrapper up top stays readable.
    private func fetchArtistInfo(_ artist: String) async throws -> ArtistInfo {
        var comps = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "artist.getinfo"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else {
            throw Error.malformed(apiBase, reason: "artist.getinfo URL")
        }
        let data = try await fetch(url)
        return try parseArtistInfo(from: data, sourceURL: url)
    }

    /// Fetch + parse behind ``trackInfo(artist:title:)``.
    private func fetchTrackInfo(artist: String, title: String) async throws -> TrackInfo {
        var comps = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "track.getinfo"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "track", value: title),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else {
            throw Error.malformed(apiBase, reason: "track.getinfo URL")
        }
        let data = try await fetch(url)
        return try parseTrackInfo(from: data, sourceURL: url)
    }

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

    private struct SimilarArtistsEnvelope: Decodable {
        let similarartists: SimilarArtistsBody?
    }

    private struct SimilarArtistsBody: Decodable {
        let artist: [SimilarArtistRaw]?
    }

    private struct SimilarArtistRaw: Decodable {
        let name: String?
    }

    private struct ArtistTopTracksEnvelope: Decodable {
        let toptracks: ArtistTopTracksBody?
    }

    private struct ArtistTopTracksBody: Decodable {
        let track: [TrackRaw]?
    }

    // artist.getinfo / track.getinfo. Same tolerance rule as above; the
    // `tags`/`toptags` rows reuse ``ArtistTagRaw`` (getinfo tags carry no
    // count, which decodes as nil and is simply unused here).

    private struct ArtistInfoEnvelope: Decodable {
        let artist: ArtistInfoRaw?
    }

    private struct ArtistInfoRaw: Decodable {
        let stats: StatsRaw?
        let tags: InfoTagsRaw?
        let similar: SimilarArtistsBody?   // same {artist:[{name}]} shape
        let bio: WikiRaw?
    }

    private struct StatsRaw: Decodable {
        let listeners: String?   // strings again, same as TrackRaw
        let playcount: String?
    }

    private struct InfoTagsRaw: Decodable {
        let tag: [ArtistTagRaw]?
    }

    private struct WikiRaw: Decodable {
        let summary: String?
        let content: String?
    }

    private struct TrackInfoEnvelope: Decodable {
        let track: TrackInfoRaw?
    }

    private struct TrackInfoRaw: Decodable {
        let listeners: String?
        let playcount: String?
        let album: TrackAlbumRaw?
        let toptags: InfoTagsRaw?
        let wiki: WikiRaw?
    }

    private struct TrackAlbumRaw: Decodable {
        let title: String?
    }
}
#endif
