#if os(macOS)
import Foundation
import OSLog

/// Orchestrator that turns a ``BandcampStationConfig`` into a stream of
/// playable, cached tracks — the Bandcamp counterpart to
/// ``LastFMStationController``.
///
/// Glue between five actors:
/// - ``BandcampClient`` supplies the raw candidate pool via
///   `releases(forTag:sort:)` over Bandcamp's private discover JSON.
///   Each candidate arrives already carrying its Bandcamp release URL,
///   which rides through the pipeline as ``SourceCandidate/resolvedURL``.
/// - ``MusicBrainzClient`` supplies authoritative release-year + country
///   metadata, used to enforce the era and region facets in the shared
///   ``FacetedPipeline`` stages.
/// - ``HistoryStore`` provides per-station dedup (don't replay a track
///   on the same station) + the skip blacklist.
/// - ``TrackResolver`` turns `(artist, title)` into a cached audio file
///   via the shared yt-dlp + YT Music pipeline. Task 10 adds a
///   direct-URL shortcut so the resolver can hand yt-dlp the Bandcamp
///   release URL straight, skipping YouTube-Music matching — this
///   controller already sets ``SourceCandidate/resolvedURL`` so that
///   shortcut lights up without further changes here.
/// - ``TasteProfile`` scores the surviving candidates against a locally
///   derived taste profile (library top artists / top tags + per-station
///   ♥-saves).
///
/// ``nextTrack()`` is the only consumer-facing entry point, mirroring
/// ``LastFMStationController/nextTrack()``. It pulls the next unseen
/// candidate, resolves it, records the play, and returns a
/// ``ResolvedTrack`` the broadcaster can hand to its decoder.
///
/// The pool is refilled with a seven-stage variant of the Last.fm
/// pipeline: per-tag scrape → tag-mode union/intersection → library +
/// blacklist exclusions → MB era filter → MB region filter → taste
/// scoring + skip blacklist → wildcard reservation / shuffle. Two
/// Last.fm-specific stages are deliberately skipped:
///
/// - **Stage 3 (popularity tier)** — Bandcamp's discover endpoint has
///   no listener count; the closest signal would be sort order, which
///   is already expressed via ``BandcampStationConfig/sort``.
/// - **Stage 5 (top-tag precision verification)** — Bandcamp tags are
///   uploader-curated, so the "artist's top-5 tags must include one of
///   the query tags" check that Last.fm needs to defuse noisy tagging
///   doesn't apply here.
///
/// Each surviving stage logs cardinality so a suspicious drop (e.g. MB
/// era filter knocking the pool to zero) is obvious in OSLog.
public actor BandcampStationController {

    public struct ResolvedTrack: Sendable {
        public let artist: String
        public let title: String
        public let cachedURL: URL
        public let youtubeID: String
        public let historyID: Int64
    }

    public enum Error: Swift.Error, Sendable {
        case poolExhausted
        case noTracksForTags([String])
        case resolveFailed(artist: String, title: String, underlying: Swift.Error)
    }

    private let config: BandcampStationConfig
    private let client: BandcampClient
    private let musicBrainz: MusicBrainzClient
    private let history: HistoryStore
    private let resolver: TrackResolver
    private let tasteProfile: TasteProfile
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "bandcamp-station")

    private var pool: [SourceCandidate] = []
    private var cursor: Int = 0

    /// Reservation ratio: what fraction of the pool is unscored wildcards
    /// vs taste-sorted top picks. Matches ``LastFMStationController`` so
    /// the two generative stations have consistent surprise-vs-preference
    /// behaviour.
    private let wildcardFraction: Double = 0.2

    public init(
        config: BandcampStationConfig,
        client: BandcampClient,
        musicBrainz: MusicBrainzClient,
        history: HistoryStore,
        resolver: TrackResolver,
        tasteProfile: TasteProfile
    ) {
        self.config = config
        self.client = client
        self.musicBrainz = musicBrainz
        self.history = history
        self.resolver = resolver
        self.tasteProfile = tasteProfile
    }

    // MARK: - Public

    /// Produce the next resolved track for this station.
    ///
    /// Mirrors ``LastFMStationController/nextTrack()``: skips candidates
    /// already in history, skips candidates with no YouTube match or
    /// transient resolver failures, refills the pool when empty, caps
    /// the retry loop at `maxAttempts` so a bad stretch can't hang.
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

            let seen = try await history.hasPlayed(
                station: config.id,
                artist: candidate.artist,
                title: candidate.title
            )
            if seen { continue }

            do {
                // Task 10 will extend the resolver to take a different
                // path when ``SourceCandidate/resolvedURL`` is set (hand
                // yt-dlp the Bandcamp URL directly, skip YT-Music
                // matching). For now we call the same (artist, title)
                // shape as the Last.fm controller; the shortcut lights
                // up once the resolver change lands, with no further
                // modifications needed here.
                let resolution = try await resolver.resolve(
                    artist: candidate.artist,
                    title: candidate.title
                )
                // Prefer the Bandcamp release URL when we have it so the
                // history row points at the actual source page (useful
                // for "where did this come from?" debugging) rather than
                // the YT-Music fallback.
                let sourceURL = candidate.resolvedURL
                    ?? URL(string: "https://music.youtube.com/watch?v=\(resolution.youtubeID)")
                    ?? URL(string: "https://bandcamp.com/")!
                let rowid = try await history.record(
                    station: config.id,
                    artist: candidate.artist,
                    title: candidate.title,
                    sourceShowURL: sourceURL,
                    youtubeID: resolution.youtubeID,
                    cachedPath: resolution.cachedURL.path
                )
                logger.info("resolved \(candidate.artist, privacy: .public) — \(candidate.title, privacy: .public)")
                return ResolvedTrack(
                    artist: candidate.artist,
                    title: candidate.title,
                    cachedURL: resolution.cachedURL,
                    youtubeID: resolution.youtubeID,
                    historyID: rowid
                )
            } catch TrackResolver.Error.noYouTubeMatch {
                logger.info("no YT match for \(candidate.artist, privacy: .public) — \(candidate.title, privacy: .public); skipping")
                continue
            } catch {
                logger.error("resolve failed for \(candidate.artist, privacy: .public) — \(candidate.title, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
        }

        throw Error.poolExhausted
    }

    // MARK: - Pool pipeline

    /// Full refill pipeline — see the class docs for the stage order.
    ///
    /// Each stage filters the in-flight collection and the final mix is
    /// split between taste-sorted top picks (80%) and random wildcards
    /// (20%) so the station doesn't converge to a predictable handful
    /// of "best scored" tracks.
    private func refillPool() async throws {
        // Stage 1: raw per-tag scrape. Fold multi-tag hits into a single
        // SourceCandidate with the accumulated matchedTags so stage 2's
        // `.all` mode sees one candidate with the combined tag set, not
        // N copies.
        //
        // `resolvedURL` is set to the Bandcamp release URL on every
        // candidate. This rides through the pipeline unchanged and will
        // enable the TrackResolver direct-URL shortcut (Task 10) to hand
        // yt-dlp the Bandcamp URL directly instead of re-searching via
        // YT Music.
        struct SeedRecord {
            var candidate: SourceCandidate
            var matchedTags: Set<String>
        }
        // Use an array as source of truth + a companion dict for dedup
        // lookups. `Dictionary.values` iteration order is non-deterministic
        // (randomized hash seeding), which would reshuffle the temporal
        // window on every refill when the user asked for `sort: .date,
        // shufflePool: false` — the fix is to preserve first-insertion
        // order so "newest first" stays deterministic.
        var seeds: [SeedRecord] = []
        var seedIndex: [DedupKey: Int] = [:]
        for tag in config.query.genreTags {
            do {
                let releases = try await client.releases(forTag: tag, sort: config.sort)
                let tagLower = tag.lowercased()
                for r in releases {
                    let key = DedupKey(artist: r.artist.lowercased(), title: r.title.lowercased())
                    if let idx = seedIndex[key] {
                        var existing = seeds[idx]
                        existing.matchedTags.insert(tagLower)
                        existing.candidate = SourceCandidate(
                            artist: existing.candidate.artist,
                            title: existing.candidate.title,
                            resolvedURL: existing.candidate.resolvedURL,
                            listenersHint: existing.candidate.listenersHint,
                            matchedTags: existing.matchedTags
                        )
                        seeds[idx] = existing
                    } else {
                        let matched: Set<String> = [tagLower]
                        let cand = SourceCandidate(
                            artist: r.artist,
                            title: r.title,
                            resolvedURL: r.releaseURL,
                            listenersHint: nil,
                            matchedTags: matched
                        )
                        seedIndex[key] = seeds.count
                        seeds.append(SeedRecord(candidate: cand, matchedTags: matched))
                    }
                }
            } catch {
                logger.info("bandcamp scrape failed for tag \(tag, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if seeds.isEmpty {
            throw Error.noTracksForTags(config.query.genreTags)
        }
        logger.info("stage1 scrape: \(seeds.count) candidates across \(self.config.query.genreTags.count) tag(s)")

        // Stage 2: tag mode (union / intersection) via the shared pipeline.
        let requiredTags = Set(config.query.genreTags.map { $0.lowercased() })
        let tagModeInput: [(SourceCandidate, Set<String>)] = seeds.map { ($0.candidate, $0.matchedTags) }
        var candidates: [SourceCandidate] = FacetedPipeline.applyTagMode(
            tagModeInput,
            required: requiredTags,
            mode: config.query.tagMatch
        )
        logger.info("stage2 tag mode: \(candidates.count) candidates remain")

        // Stage 3: popularity tier — SKIPPED for Bandcamp. The discover
        // endpoint exposes no listener count; the closest signal is the
        // sort order, which is already selected up-front via
        // ``BandcampStationConfig/sort``.

        // Stage 4: library + artist exclusions via the shared pipeline.
        // Runs BEFORE the MB-expensive filters so we don't spend HTTP
        // budget on candidates we're about to drop anyway.
        candidates = await FacetedPipeline.applyExclusions(
            candidates,
            excludedArtists: config.query.excludedArtists,
            excludeOwnedLibrary: config.query.excludeOwnedLibrary,
            tasteProfile: tasteProfile
        )
        logger.info("stage4 exclusions: \(candidates.count) candidates remain")

        // Stage 5: top-tag precision — SKIPPED for Bandcamp. The Last.fm
        // pipeline uses `artist.getTopTags` to defuse noisy user-applied
        // tagging (the Exaltasamba bug); Bandcamp tags are uploader-
        // curated so there's no analogous noise layer to filter out.

        // Stage 6: MB era filter — enforce `config.query.yearMin/yearMax`
        // via the shared pipeline. Fail-open for unknown MB entries.
        candidates = await FacetedPipeline.applyEraFilter(
            candidates,
            yearMin: config.query.yearMin,
            yearMax: config.query.yearMax,
            mb: musicBrainz
        )
        logger.info("stage6 era: \(candidates.count) candidates remain")

        // Stage 7: MB region filter — enforce `config.query.regions` via
        // the shared pipeline. Also fail-open; one MB call per unique
        // artist courtesy of the pipeline's internal cache.
        candidates = await FacetedPipeline.applyRegionFilter(
            candidates,
            regions: config.query.regions,
            mb: musicBrainz
        )
        logger.info("stage7 region: \(candidates.count) candidates remain")

        // Stage 8: skip blacklist + taste scoring. Drop negative-scored
        // (skipped) candidates and sort the rest high→low. Same shape as
        // Last.fm's stage 8 — reads matched tags straight off the
        // candidate.
        var scored: [(cand: SourceCandidate, score: Double)] = []
        for c in candidates {
            let s = await tasteProfile.score(
                candidateArtist: c.artist,
                candidateTags: Array(c.matchedTags),
                stationID: config.id,
                history: history
            )
            if s < 0 { continue }     // skip blacklist hit
            scored.append((c, s))
        }
        scored.sort { $0.score > $1.score }
        logger.info("stage8 scored: \(scored.count) candidates ranked")

        if scored.isEmpty {
            pool = []
            cursor = 0
            throw Error.noTracksForTags(config.query.genreTags)
        }

        // Stage 9: wildcard reservation + optional shuffle. Honors
        // `config.shufflePool`: false preserves the scrape-order, which
        // matters when `sort: .date` is picked — the user asked for
        // "newest first", so we ship newest first. True mixes a top /
        // wildcard interleave plus a soft in-window shuffle so the
        // station doesn't always lead with the same top-scored pick.
        if config.shufflePool {
            let wildcardCount = max(1, Int(Double(scored.count) * wildcardFraction))
            let topCount = max(scored.count - wildcardCount, 0)
            let topSlice = Array(scored.prefix(topCount)).map { $0.cand }
            var wildcardSlice = Array(scored.suffix(wildcardCount)).map { $0.cand }
            wildcardSlice.shuffle()

            pool = interleave(topSlice, wildcardSlice)
            pool = softShuffle(pool, window: 4)
            cursor = 0
            logger.info("stage9 pool ready: \(self.pool.count) candidates (wildcards: \(wildcardCount))")
        } else {
            // Temporal mode: keep the scrape order intact. Skip blacklist
            // already applied via stage 8's score-filter.
            pool = scored.map { $0.cand }
            cursor = 0
            logger.info("stage9 pool ready: \(self.pool.count) candidates (order preserved)")
        }
    }

    // MARK: - Helpers

    private struct DedupKey: Hashable {
        let artist: String
        let title: String
    }

    /// Interleave `primary` with `secondary` — take one from each as
    /// long as both are non-empty, then append whichever still has
    /// items. Yields a "scored, wildcard, scored, wildcard, …" ordering.
    private func interleave<T>(_ primary: [T], _ secondary: [T]) -> [T] {
        var out: [T] = []
        out.reserveCapacity(primary.count + secondary.count)
        var i = 0, j = 0
        while i < primary.count || j < secondary.count {
            if i < primary.count { out.append(primary[i]); i += 1 }
            if j < secondary.count { out.append(secondary[j]); j += 1 }
        }
        return out
    }

    /// Shuffle within fixed-size windows. Preserves coarse ordering
    /// (top-ranked slice stays near the front) while jittering the
    /// first-play pick so we don't always lead with the same track.
    private func softShuffle<T>(_ items: [T], window: Int) -> [T] {
        var out: [T] = []
        out.reserveCapacity(items.count)
        var i = 0
        while i < items.count {
            let end = min(i + window, items.count)
            out.append(contentsOf: items[i..<end].shuffled())
            i = end
        }
        return out
    }
}
#endif
