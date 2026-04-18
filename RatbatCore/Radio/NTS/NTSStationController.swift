#if os(macOS)
import Foundation
import OSLog

/// Orchestrator that turns an ``NTSStationConfig`` into a stream of
/// playable, cached tracks.
///
/// The controller is the glue layer between three actors:
///
/// - ``NTSClient`` supplies the candidate pool (shows → tracklists for
///   the configured tags).
/// - ``HistoryStore`` provides per-station dedup and records each play.
/// - ``TrackResolver`` turns an (artist, title) pair into a cached
///   audio file via YouTube Music + yt-dlp.
///
/// ``nextTrack()`` is the only consumer-facing entry point. It pulls
/// the next unseen candidate, resolves it, records the play, and
/// returns a ``ResolvedTrack`` the broadcaster can hand to its decoder.
///
/// The pool is lazily refilled from NTS — we fetch a batch of shows
/// for the tags, then drain them one tracklist at a time. When the
/// pool runs dry we refill; when no more shows are available we throw
/// ``Error/poolExhausted``. Callers (the broadcaster) are expected to
/// decide what to do: widen tags, wait, stop.
public actor NTSStationController {

    public struct ResolvedTrack: Sendable {
        public let artist: String
        public let title: String
        public let cachedURL: URL
        public let youtubeID: String
        public let historyID: Int64    // HistoryStore rowid — for later ♥-save
        public let sourceShowURL: URL
    }

    public enum Error: Swift.Error, Sendable {
        case poolExhausted
        case noShowsForTags([String])
        case noTracklistsAvailable
        case resolveFailed(artist: String, title: String, underlying: Swift.Error)
    }

    private let config: NTSStationConfig
    private let nts: NTSClient
    private let history: HistoryStore
    private let resolver: TrackResolver
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "nts-station")

    /// Scraped candidate pool. Refilled from NTS when the cursor runs
    /// past the end.
    private var pool: [NTSClient.Tracklisting] = []
    private var cursor: Int = 0

    /// Cached list of shows matching the station's tags. We drain two
    /// or three shows per pool refill so NTS isn't hammered on every
    /// single `nextTrack()` call.
    private var shows: [NTSClient.Show] = []
    private var showCursor: Int = 0

    public init(
        config: NTSStationConfig,
        nts: NTSClient,
        history: HistoryStore,
        resolver: TrackResolver
    ) {
        self.config = config
        self.nts = nts
        self.history = history
        self.resolver = resolver
    }

    /// Produce the next resolved track for this station.
    ///
    /// Skips anything already in history. Skips candidates with no
    /// YouTube match or transient resolver failures. Refills the pool
    /// when needed. Caps the retry loop at `maxAttempts` so the call
    /// can't hang indefinitely if every candidate fails.
    ///
    /// - Throws: ``Error/poolExhausted`` when the pool is empty and
    ///   can't be refilled (no more shows, or the `maxAttempts` cap
    ///   was hit without a successful resolve).
    public func nextTrack() async throws -> ResolvedTrack {
        let maxAttempts = 30
        var attempts = 0

        while attempts < maxAttempts {
            attempts += 1

            if cursor >= pool.count {
                try await refillPool()
            }
            guard cursor < pool.count else {
                throw Error.poolExhausted
            }

            let candidate = pool[cursor]
            cursor += 1

            // Dedup against history.
            let seen = try await history.hasPlayed(
                station: config.id,
                artist: candidate.artist,
                title: candidate.title
            )
            if seen { continue }

            // (Year / duration filters would slot in here. Deferred to v2.)

            do {
                let resolution = try await resolver.resolve(
                    artist: candidate.artist,
                    title: candidate.title
                )
                let rowid = try await history.record(
                    station: config.id,
                    artist: candidate.artist,
                    title: candidate.title,
                    sourceShowURL: candidate.showURL,
                    youtubeID: resolution.youtubeID,
                    cachedPath: resolution.cachedURL.path
                )
                logger.info("resolved \(candidate.artist, privacy: .public) — \(candidate.title, privacy: .public)")
                return ResolvedTrack(
                    artist: candidate.artist,
                    title: candidate.title,
                    cachedURL: resolution.cachedURL,
                    youtubeID: resolution.youtubeID,
                    historyID: rowid,
                    sourceShowURL: candidate.showURL
                )
            } catch TrackResolver.Error.noYouTubeMatch {
                // Don't record — if the YT catalog adds a match later
                // we'd rather play it than carry a silent skip forward.
                logger.info("no YT match for \(candidate.artist, privacy: .public) — \(candidate.title, privacy: .public); skipping")
                continue
            } catch {
                logger.error("resolve failed for \(candidate.artist, privacy: .public) — \(candidate.title, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
        }

        throw Error.poolExhausted
    }

    // MARK: - Pool management

    /// Fetch fresh tracklists from NTS when the pool runs low.
    ///
    /// Pulls two or three shows per refill so the pool has breadth
    /// without triggering an NTS fetch on every single dequeue. If the
    /// cached show list is empty, it's refreshed first.
    private func refillPool() async throws {
        if showCursor >= shows.count {
            try await refreshShows()
        }
        guard showCursor < shows.count else {
            throw Error.noShowsForTags(config.query.genreTags)
        }

        var collected: [NTSClient.Tracklisting] = []
        let take = min(3, shows.count - showCursor)
        for _ in 0..<take {
            let show = shows[showCursor]
            showCursor += 1
            do {
                var listings = try await nts.tracklist(for: show.url)
                if config.shufflePool {
                    listings.shuffle()
                }
                collected.append(contentsOf: listings)
            } catch {
                logger.info("skip show with unfetchable tracklist: \(show.url.absoluteString, privacy: .public)")
            }
        }

        if collected.isEmpty {
            throw Error.noTracklistsAvailable
        }

        pool = collected
        cursor = 0
        logger.info("refilled pool with \(collected.count) candidates")
    }

    /// Fetch the show list for each configured tag, dedup by URL,
    /// optionally shuffle.
    private func refreshShows() async throws {
        var seen: Set<URL> = []
        var collected: [NTSClient.Show] = []
        for tag in config.query.genreTags {
            do {
                let fetched = try await nts.shows(forTag: tag, limit: 20)
                for s in fetched where !seen.contains(s.url) {
                    seen.insert(s.url)
                    collected.append(s)
                }
            } catch {
                logger.info("shows fetch failed for tag \(tag, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if config.shufflePool {
            collected.shuffle()
        }
        shows = collected
        showCursor = 0
        let tagList = config.query.genreTags.joined(separator: ", ")
        logger.info("refreshed shows pool: \(collected.count) shows for tags \(tagList, privacy: .public)")
    }
}
#endif
