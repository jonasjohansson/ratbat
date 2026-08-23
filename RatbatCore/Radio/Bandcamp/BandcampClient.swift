#if os(macOS)
import Foundation
import OSLog

/// A single Bandcamp release surfaced by the discover endpoint.
///
/// Albums only. The discover API takes an explicit
/// `include_result_types` list and `["a"]` is the only value it accepts —
/// asking for `["t"]` or `["a","t"]` comes back HTTP 200 carrying
/// `{"__api_special__":"exception"}`. Bedroom-producer singles are still
/// reachable, because Bandcamp models a standalone single as a one-track
/// album; what is gone is the ability to ask for loose tracks separately.
public struct BandcampRelease: Sendable, Hashable {
    public let artist: String
    public let title: String
    public let releaseURL: URL
    public let releaseDate: Date?

    /// Title of the release's FEATURED TRACK, from the discover listing.
    ///
    /// Parsed rather than dropped because the pairing is the point: a
    /// duration with no name attached is how an exclusion row ends up
    /// saying "dropped for length" without ever saying *whose* length.
    /// The v3 payload carried this title too and the old parser threw it
    /// away. No caller consumes it yet — ``SelectionSubject`` has no slot
    /// for it — but the model is no longer the reason it is missing.
    public let featuredTrackTitle: String?

    /// Length of the release's FEATURED TRACK, from the discover listing.
    ///
    /// Read the name literally. This is one track's length, and the
    /// candidate is the RELEASE — `title` above is the release title, and
    /// the release is what this station plays. So a mix-set exclusion
    /// driven by this number removes a whole release on the strength of
    /// one track.
    ///
    /// That is why the exclusion log stamps `duration_source` as
    /// `listing-featured-track` and not `listing`: the reader has to be
    /// able to tell what was actually measured from what was actually
    /// dropped. ``featuredTrackTitle`` above says which track that was.
    public let featuredTrackDurationSeconds: TimeInterval?

    public init(
        artist: String,
        title: String,
        releaseURL: URL,
        releaseDate: Date?,
        featuredTrackTitle: String? = nil,
        featuredTrackDurationSeconds: TimeInterval? = nil
    ) {
        self.artist = artist
        self.title = title
        self.releaseURL = releaseURL
        self.releaseDate = releaseDate
        self.featuredTrackTitle = featuredTrackTitle
        self.featuredTrackDurationSeconds = featuredTrackDurationSeconds
    }
}

/// Thin wrapper around Bandcamp's private `/api/discover/1/discover_web`
/// JSON endpoint. We lean on this instead of the public `/tag/<slug>`
/// page because (a) `/tag/<slug>` now 301s to `/discover/<slug>`, a Vue
/// SPA with no release data in the initial HTML, and (b) the JSON
/// endpoint is the same one the SPA itself calls, so it's the stable
/// contract.
///
/// ## Why not `/api/discover/3/get_web`
///
/// Because it lies. The v3 endpoint — which this client used until the
/// migration — still answers 200 and still returns well-formed items,
/// but it silently stopped honouring its `t=<tag>` parameter. Requests
/// for `techno`, `ambient` and `death-metal` come back with the same 48
/// items in the same order and the same `total_count` of 3939; the only
/// bytes that differ between them are the response timestamp and the
/// per-request signing token inside each `mp3-128` stream URL. What v3
/// serves now is an unfiltered new-releases firehose.
///
/// A station is a tag. An endpoint that ignores the tag is not a
/// degraded station, it is a different product: the user's "Techno"
/// station was broadcasting punk, orchestral and upload spam, and
/// nothing in the pipeline could tell, because every downstream stage
/// trusts stage 1 to have already filtered by genre. So there is no
/// fallback to v3 here — a silent wrong answer is worse than a loud
/// empty pool, and `noTracksForTags` at least takes the station off air
/// instead of misrepresenting it.
///
/// The v1 endpoint filters for real (verified: `death-metal` →
/// Atomizer / ARTEFACTS, `ambient` → Ophibre / Codasync) and pages by
/// opaque `cursor` rather than by page index.
///
/// Rate-limited to 0.5s between outbound requests — Bandcamp hasn't
/// published a rate limit for this endpoint and 500ms is comfortable.
public actor BandcampClient {

    public enum Error: Swift.Error, Sendable {
        case badResponse(URL)
        /// The endpoint answered 200 with `{"__api_special__":"exception"}`.
        /// Bandcamp reports request-shape errors in the body rather than
        /// the status line, so this has to be sniffed for explicitly or it
        /// decodes as a successful, empty page.
        case apiException(String)
    }

    /// User-facing sort. We deliberately avoid leaking the endpoint's
    /// internal vocabulary (`new`/`top`) into the Swift surface because
    /// those strings will eventually end up in a Station UI picker, and
    /// `.date` / `.pop` reads better there.
    public enum Sort: String, Sendable, Codable, Hashable {
        case date       // → slice "new"
        case pop        // → slice "top"

        /// The wire vocabulary. Both slices verified live and genuinely
        /// distinct: `top` surfaces established names (Lusine, Clark,
        /// Max Cooper for `techno`) where `new` surfaces today's uploads.
        var slice: String {
            switch self {
            case .date: return "new"
            case .pop:  return "top"
            }
        }
    }

    private static let apiBase = URL(string: "https://bandcamp.com/api/discover/1/discover_web")!

    /// Results per request. Held at 48 to match what the v3 page size
    /// used to be, so `maxPages` still means the same pool depth to
    /// ``BandcampStationController`` as it did before the migration.
    private static let pageSize = 48

    private let userAgent: String
    private let session: URLSession
    private static let logger = Logger(subsystem: RatbatLog.subsystem, category: "bandcamp")
    private var lastRequestAt: Date?

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    // MARK: - Public

    public func releases(forTag tag: String, sort: Sort = .date, maxPages: Int = 5) async throws -> [BandcampRelease] {
        var all: [BandcampRelease] = []
        let slug = tag.lowercased().replacingOccurrences(of: " ", with: "-")
        var cursor: String?

        for page in 0..<maxPages {
            do {
                let body = try Self.requestBody(slug: slug, sort: sort, cursor: cursor)
                let data = try await throttledFetch(body: body)
                let batch = Self.parseDiscoverBatch(data: data)
                if batch.releases.isEmpty { break }
                all.append(contentsOf: batch.releases)

                // Cursor paging has no total to count against, so the tail
                // is detected from the cursor itself:
                //  - absent means the server has nothing more to hand out
                //    (an unknown tag returns `cursor: null` on the first
                //    batch, with zero results);
                //  - unchanged means we would re-request the same window
                //    forever, which is the cursor-shaped version of an
                //    infinite loop.
                guard let next = batch.cursor, !next.isEmpty, next != cursor else { break }
                cursor = next
            } catch {
                Self.logger.info("bandcamp tag \(tag, privacy: .public) page \(page): \(String(describing: error), privacy: .public)")
                break
            }
        }
        Self.logger.info("bandcamp releases(tag: \(tag, privacy: .public), slice: \(sort.slice, privacy: .public)): \(all.count)")
        return all
    }

    // MARK: - Internal (exposed for @testable tests)

    /// Build the POST body for one discover batch.
    ///
    /// `tag_norm_names` is the whole point of the migration — it is the
    /// parameter v3's `t=` stopped honouring — so it is built here rather
    /// than string-interpolated at the call site, and
    /// `BandcampClientTests` asserts against the encoded bytes that the
    /// slug actually reaches the wire.
    static func requestBody(slug: String, sort: Sort, cursor: String?) throws -> Data {
        var payload: [String: Any] = [
            "tag_norm_names": [slug],
            // Albums only; see ``BandcampRelease``. Not a filter we chose,
            // it is the only value the endpoint accepts.
            "include_result_types": ["a"],
            "slice": sort.slice,
            "size": pageSize,
        ]
        // Omitted, not null, on the first batch — the endpoint treats a
        // present-but-null cursor as a malformed request.
        if let cursor, !cursor.isEmpty { payload["cursor"] = cursor }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Parse a `/api/discover/1/discover_web` JSON response into releases
    /// plus the cursor for the next batch.
    ///
    /// Returns `([], nil)` if the structure doesn't match — treated as
    /// "endpoint restructured" by callers (caller logs + moves on).
    static func parseDiscoverBatch(data: Data) -> (releases: [BandcampRelease], cursor: String?) {
        struct Envelope: Decodable {
            struct Result: Decodable {
                let title: String?
                let itemURL: String?
                let bandName: String?
                /// Set when the release is credited to someone other than
                /// the page owner — a label page publishing a signed
                /// artist, or a collaboration. Preferred over `band_name`
                /// when present, otherwise a label's whole catalogue
                /// collapses to one "artist" and the dedup key, the taste
                /// profile and the MusicBrainz lookups all key off the
                /// label instead of the musician.
                let albumArtist: String?
                let releaseDate: String?
                let featuredTrack: FeaturedTrack?
                enum CodingKeys: String, CodingKey {
                    case title
                    case itemURL = "item_url"
                    case bandName = "band_name"
                    case albumArtist = "album_artist"
                    case releaseDate = "release_date"
                    case featuredTrack = "featured_track"
                }
            }
            /// The one track the discover listing previews. Optional
            /// throughout: absent items must decode, not fail the batch —
            /// 1 of the 48 items in `bandcamp-discover-techno` has no
            /// featured track at all, and it is still a real album.
            struct FeaturedTrack: Decodable {
                let title: String?
                let duration: Double?
            }
            let results: [Result]?
            let cursor: String?
        }

        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return ([], nil)
        }

        // Bandcamp release_date is space-separated with a literal zone
        // name: "2026-08-22 00:00:00 UTC". Not ISO 8601 (no `T`, no
        // offset). `en_US_POSIX` locale + explicit GMT timezone avoids the
        // ambiguous-zzz parsing issue on some locales.
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
            return f
        }()

        let releases: [BandcampRelease] = (env.results ?? []).compactMap { item in
            // title / artist / url are required (non-empty)
            guard
                let title = item.title, !title.isEmpty,
                let raw = item.itemURL, !raw.isEmpty
            else { return nil }

            let artist = [item.albumArtist, item.bandName]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            guard let artist else { return nil }

            // Every `item_url` arrives tagged `?from=discover_page`.
            // Strip it: this URL is a dedup key, a history row and the
            // argument handed to yt-dlp's BandcampIE, and an analytics
            // param has no business in any of those three.
            guard let url = Self.canonicalReleaseURL(raw) else { return nil }

            let date: Date? = item.releaseDate.flatMap { dateFormatter.date(from: $0) }
            return BandcampRelease(
                artist: artist,
                title: title,
                releaseURL: url,
                releaseDate: date,
                // Carried, not consumed, here — see the fields' own docs
                // for what this number does and does not measure.
                featuredTrackTitle: item.featuredTrack?.title,
                featuredTrackDurationSeconds: item.featuredTrack?.duration
            )
        }

        if let rawCount = env.results?.count, releases.count < rawCount {
            BandcampClient.logger.info("bandcamp parse: \(releases.count)/\(rawCount) results kept — possible partial schema drift")
        }

        return (releases, env.cursor)
    }

    /// Drop the query string from a discover `item_url`.
    ///
    /// Only the query — path, host and fragment are left alone, because
    /// the release identity lives there.
    static func canonicalReleaseURL(_ raw: String) -> URL? {
        guard var comps = URLComponents(string: raw) else { return nil }
        comps.query = nil
        guard let url = comps.url, url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    // MARK: - Private

    private func throttledFetch(body: Data) async throws -> Data {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            let minGap: TimeInterval = 0.5
            if elapsed < minGap {
                try await Task.sleep(nanoseconds: UInt64((minGap - elapsed) * 1_000_000_000))
            }
        }
        // Reserve the slot BEFORE the await — pre-setting is deliberate, not a
        // bug. Setting lastRequestAt after the response would let two concurrent
        // tasks both read a stale gate and fire simultaneously, blowing past
        // the 500ms cap. Same rationale as MusicBrainzClient.
        lastRequestAt = Date()

        let url = Self.apiBase
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.badResponse(url)
        }
        // A rejected request shape (e.g. an unsupported
        // `include_result_types`) comes back 200 with an exception
        // envelope. Left unchecked it decodes as a perfectly good page
        // with no results, which is exactly the class of silent-wrong-
        // answer that put us on this endpoint in the first place.
        if let special = Self.apiSpecialError(in: data) {
            throw Error.apiException(special)
        }
        return data
    }

    /// Sniff Bandcamp's in-body error envelope.
    private static func apiSpecialError(in data: Data) -> String? {
        struct Special: Decodable {
            let apiSpecial: String?
            let errorType: String?
            enum CodingKeys: String, CodingKey {
                case apiSpecial = "__api_special__"
                case errorType = "error_type"
            }
        }
        guard
            let special = try? JSONDecoder().decode(Special.self, from: data),
            special.apiSpecial == "exception"
        else { return nil }
        return special.errorType ?? "unknown"
    }
}
#endif
