#if os(macOS)
import Foundation
import OSLog

/// A single Bandcamp release surfaced by the discover endpoint.
///
/// Both albums (`item_type == "a"`) and tracks (`item_type == "t"`) are
/// represented here — both are legitimate release shapes on Bandcamp, and
/// filtering out tracks at scrape time loses a lot of valid bedroom-producer
/// singles.
public struct BandcampRelease: Sendable, Hashable {
    public let artist: String
    public let title: String
    public let releaseURL: URL
    public let releaseDate: Date?

    /// Length of the release's FEATURED TRACK, from the discover listing.
    ///
    /// Read the name literally. This is one track's length, and for an
    /// album candidate — which is what the discover endpoint overwhelmingly
    /// returns; all 48 items of the `bandcamp-discover-techno` fixture are
    /// `type: "a"` — the thing this station plays is the RELEASE, and
    /// `title` above is the release title. So a mix-set exclusion driven by
    /// this number removes a whole release on the strength of one track.
    /// Four of those 48 fixture items exceed the 20-minute threshold on the
    /// featured track alone.
    ///
    /// That is why the exclusion log stamps `duration_source` as
    /// `listing-featured-track` and not `listing`: the reader has to be
    /// able to tell what was actually measured from what was actually
    /// dropped.
    public let featuredTrackDurationSeconds: TimeInterval?

    public init(
        artist: String,
        title: String,
        releaseURL: URL,
        releaseDate: Date?,
        featuredTrackDurationSeconds: TimeInterval? = nil
    ) {
        self.artist = artist
        self.title = title
        self.releaseURL = releaseURL
        self.releaseDate = releaseDate
        self.featuredTrackDurationSeconds = featuredTrackDurationSeconds
    }
}

/// Thin wrapper around Bandcamp's private `/api/discover/3/get_web` JSON
/// endpoint. We lean on this instead of the public `/tag/<slug>` page
/// because (a) `/tag/<slug>` now 301s to `/discover/<slug>`, a Vue SPA
/// with no release data in the initial HTML, and (b) the JSON endpoint
/// is the same one the SPA itself calls, so it's the stable contract.
///
/// Rate-limited to 0.5s between outbound requests — Bandcamp hasn't
/// published a rate limit for this endpoint and 500ms is comfortable.
public actor BandcampClient {

    public enum Error: Swift.Error, Sendable {
        case badResponse(URL)
    }

    /// User-facing sort. We deliberately avoid leaking the endpoint's
    /// internal vocabulary (`new`/`top`/`rec`) into the Swift surface
    /// because those strings will eventually end up in a Station UI
    /// picker, and `.date` / `.pop` reads better there.
    public enum Sort: String, Sendable, Codable, Hashable {
        case date       // → "s=new"
        case pop        // → "s=top"
    }

    private static let apiBase = URL(string: "https://bandcamp.com/api/discover/3/get_web")!
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
        let sortParam: String = (sort == .date) ? "new" : "top"

        for page in 0..<maxPages {
            var comps = URLComponents(url: Self.apiBase, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "g", value: "0"),      // genre id — 0 = all
                URLQueryItem(name: "gn", value: "0"),     // genre "no genre" flag
                URLQueryItem(name: "f", value: "all"),    // time filter: all-time
                URLQueryItem(name: "t", value: slug),     // tag slug
                URLQueryItem(name: "s", value: sortParam),
                URLQueryItem(name: "p", value: "\(page)"),
            ]
            guard let url = comps.url else { break }
            do {
                let data = try await throttledFetch(url)
                let (pageReleases, totalCount) = Self.parseDiscoverPage(data: data)
                if pageReleases.isEmpty { break }
                all.append(contentsOf: pageReleases)
                // Two independent stop conditions:
                //  - `more_available` is always null, so we can't use it.
                //  - A short page (< 48 items) means we're at the tail.
                //  - Otherwise, `total_count` tells us if there's more.
                if pageReleases.count < 48 { break }
                if (page + 1) * 48 >= totalCount { break }
            } catch {
                Self.logger.info("bandcamp tag \(tag, privacy: .public) page \(page): \(String(describing: error), privacy: .public)")
                break
            }
        }
        Self.logger.info("bandcamp releases(tag: \(tag, privacy: .public)): \(all.count)")
        return all
    }

    // MARK: - Internal (exposed for @testable tests)

    /// Parse a `/api/discover/3/get_web` JSON response into releases.
    /// Returns `([], 0)` if the structure doesn't match — treated as
    /// "endpoint restructured" by callers (caller logs + moves on).
    static func parseDiscoverPage(data: Data) -> (releases: [BandcampRelease], totalCount: Int) {
        struct Envelope: Decodable {
            struct Item: Decodable {
                let type: String?
                let primaryText: String?
                let secondaryText: String?
                let publishDate: String?
                let urlHints: URLHints?
                let featuredTrack: FeaturedTrack?
                enum CodingKeys: String, CodingKey {
                    case type
                    case primaryText = "primary_text"
                    case secondaryText = "secondary_text"
                    case publishDate = "publish_date"
                    case urlHints = "url_hints"
                    case featuredTrack = "featured_track"
                }
            }
            /// The one track the discover listing previews. Optional
            /// throughout: absent items must decode, not fail the page.
            struct FeaturedTrack: Decodable {
                let duration: Double?
                let title: String?
            }
            struct URLHints: Decodable {
                let subdomain: String?
                let customDomain: String?
                let slug: String?
                let itemType: String?
                enum CodingKeys: String, CodingKey {
                    case subdomain, slug
                    case customDomain = "custom_domain"
                    case itemType = "item_type"
                }
            }
            let items: [Item]?
            let totalCount: Int?
            enum CodingKeys: String, CodingKey {
                case items
                case totalCount = "total_count"
            }
        }

        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return ([], 0)
        }

        // Bandcamp publish_date is RFC 1123-style:
        //   "18 Apr 2026 06:26:44 GMT"
        // Not ISO 8601. `en_US_POSIX` locale + explicit GMT timezone
        // avoids the ambiguous-zzz parsing issue on some locales.
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "d MMM yyyy HH:mm:ss zzz"
            return f
        }()

        let releases: [BandcampRelease] = (env.items ?? []).compactMap { item in
            // title / artist are required (non-empty)
            guard
                let title = item.primaryText, !title.isEmpty,
                let artist = item.secondaryText, !artist.isEmpty,
                let hints = item.urlHints,
                let slug = hints.slug, !slug.isEmpty,
                let itemType = hints.itemType, !itemType.isEmpty  // "a" (album) or "t" (track)
            else { return nil }

            // Build the release URL. Prefer custom domain; else subdomain.bandcamp.com.
            let pathSegment = (itemType == "a") ? "album" : "track"
            let urlString: String
            if let custom = hints.customDomain, !custom.isEmpty {
                urlString = "https://\(custom)/\(pathSegment)/\(slug)"
            } else if let subdomain = hints.subdomain, !subdomain.isEmpty {
                urlString = "https://\(subdomain).bandcamp.com/\(pathSegment)/\(slug)"
            } else {
                return nil
            }
            guard let url = URL(string: urlString) else { return nil }

            let date: Date? = item.publishDate.flatMap { dateFormatter.date(from: $0) }
            return BandcampRelease(
                artist: artist,
                title: title,
                releaseURL: url,
                releaseDate: date,
                // Carried, not consumed, here — see the field's own doc for
                // what this number does and does not measure.
                featuredTrackDurationSeconds: item.featuredTrack?.duration
            )
        }

        if let rawCount = env.items?.count, releases.count < rawCount {
            BandcampClient.logger.info("bandcamp parse: \(releases.count)/\(rawCount) items kept — possible partial schema drift")
        }

        return (releases, env.totalCount ?? 0)
    }

    // MARK: - Private

    private func throttledFetch(_ url: URL) async throws -> Data {
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

        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.badResponse(url)
        }
        return data
    }
}
#endif
