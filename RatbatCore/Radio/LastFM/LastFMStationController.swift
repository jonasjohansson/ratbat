#if os(macOS)
import Foundation
import OSLog

/// Orchestrator that turns a ``LastFMStationConfig`` into a stream of
/// playable, cached tracks — the Last.fm counterpart to
/// ``NTSStationController``.
///
/// Glue between five actors:
/// - ``LastFMClient`` supplies the raw candidate pool via
///   `tag.getTopTracks` and the per-artist top-tag list used by the
///   precision filter.
/// - ``MusicBrainzClient`` supplies authoritative release-year + country
///   metadata, used to enforce the era and region facets in the shared
///   ``FacetedPipeline`` stages.
/// - ``HistoryStore`` provides per-station dedup (don't replay a track
///   on the same station) + the skip blacklist.
/// - ``TrackResolver`` turns `(artist, title)` into a cached audio file
///   via the shared yt-dlp + YT Music pipeline.
/// - ``TasteProfile`` scores the surviving candidates against a locally
///   derived taste profile (library top artists / top tags + per-station
///   ♥-saves).
///
/// ``nextTrack()`` is the only consumer-facing entry point. It pulls the
/// next unseen candidate, resolves it, records the play, and returns a
/// ``ResolvedTrack`` the broadcaster can hand to its decoder.
///
/// The pool is refilled from Last.fm with a nine-stage pipeline: per-tag
/// seed fetch → tag-mode union/intersection → popularity tier → library
/// + blacklist exclusions → precision verification → MB era filter →
/// MB region filter → taste scoring + skip blacklist → wildcard
/// reservation. Post-fetch stages 2, 4, 6, 7 live in ``FacetedPipeline``
/// (shared with Bandcamp); stages 3, 5, 8, 9 stay here because they rely
/// on Last.fm-specific signals (listener counts, `artist.getTopTags`,
/// taste scoring, wildcard shuffle).
///
/// Each stage logs surviving cardinality so a suspicious drop (e.g. MB
/// era filter knocking the pool to zero) is obvious in OSLog.
public actor LastFMStationController {

    public struct ResolvedTrack: Sendable {
        public let artist: String
        public let title: String
        public let cachedURL: URL
        public let youtubeID: String
        public let historyID: Int64
        /// Display metadata the resolver's extractor already knew. `nil`
        /// where it didn't report one — Last.fm's own chart data has no
        /// album/artwork, so everything here comes from the YouTube Music
        /// match, which fills album inconsistently.
        public let album: String?
        public let duration: TimeInterval?
        public let artworkURL: String?
    }

    public enum Error: Swift.Error, Sendable {
        case poolExhausted
        case noTracksForTags([String])
        case resolveFailed(artist: String, title: String, underlying: Swift.Error)
    }

    private let config: LastFMStationConfig
    private let client: LastFMClient
    private let musicBrainz: MusicBrainzClient
    private let history: HistoryStore
    private let resolver: TrackResolver
    private let tasteProfile: TasteProfile
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "lastfm-station")

    private var pool: [SourceCandidate] = []
    private var cursor: Int = 0

    /// Reservation ratio: what fraction of the pool is unscored wildcards
    /// vs taste-sorted top picks. 0.2 = 20% wildcards, matches the design
    /// doc. Kept as a constant until we see a reason to expose it.
    private let wildcardFraction: Double = 0.2

    public init(
        config: LastFMStationConfig,
        client: LastFMClient,
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
    /// Mirrors ``NTSStationController/nextTrack()``: skips candidates
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
                let resolution = try await resolver.resolve(
                    artist: candidate.artist,
                    title: candidate.title
                )
                let sourceURL = URL(string: "https://music.youtube.com/watch?v=\(resolution.youtubeID)")
                    ?? URL(string: "https://www.last.fm/")!
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
                    historyID: rowid,
                    album: resolution.album,
                    duration: resolution.duration,
                    artworkURL: resolution.artworkURL
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
        // Stage 1: raw per-tag fetch. Collect `(SourceCandidate, matchedTags)`
        // tuples directly so stage 2 can be a single call into the pipeline.
        // The per-DedupKey merge folds multi-tag hits together before we
        // hand them off — stage 2's `.all` mode needs a single candidate
        // with the combined tag set, not N copies.
        struct SeedRecord {
            var candidate: SourceCandidate
            var matchedTags: Set<String>
        }
        // Query tags, lowercased. Needed by both the similar-artist
        // expansion (stage 1b) and tag-mode (stage 2), so compute once.
        let requiredTags = Set(config.query.genreTags.map { $0.lowercased() })

        var seeds: [DedupKey: SeedRecord] = [:]
        for tag in config.query.genreTags {
            do {
                let tracks = try await client.topTracks(forTag: tag, limit: 200)
                for t in tracks {
                    let key = DedupKey(artist: t.artist.lowercased(), title: t.title.lowercased())
                    let tagLower = tag.lowercased()
                    if var existing = seeds[key] {
                        existing.matchedTags.insert(tagLower)
                        // Keep the already-stored candidate but layer the
                        // freshly matched tag in.
                        existing.candidate = SourceCandidate(
                            artist: existing.candidate.artist,
                            title: existing.candidate.title,
                            resolvedURL: existing.candidate.resolvedURL,
                            listenersHint: existing.candidate.listenersHint,
                            matchedTags: existing.matchedTags
                        )
                        seeds[key] = existing
                    } else {
                        let matched: Set<String> = [tagLower]
                        let cand = SourceCandidate(
                            artist: t.artist,
                            title: t.title,
                            resolvedURL: nil,
                            listenersHint: t.listeners,
                            matchedTags: matched
                        )
                        seeds[key] = SeedRecord(candidate: cand, matchedTags: matched)
                    }
                }
            } catch {
                logger.info("topTracks fetch failed for tag \(tag, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        logger.info("stage1 fetch: \(seeds.count) seed candidates across \(self.config.query.genreTags.count) tag(s)")

        // Stage 1b: similar-artist expansion — the discovery multiplier.
        // Take the artists the user engages with most ON THIS station
        // (saves + play-throughs), ask Last.fm for their neighbours, and
        // fold those neighbours' top tracks into the seed pool. Tagged with
        // the query tags so they flow through the normal precision / era /
        // region / taste pipeline — only genre-coherent neighbours survive,
        // which keeps the station on-theme while steadily broadening it
        // toward "more artists like the ones you love." Hard-bounded so a
        // refill can't blow the Last.fm rate budget.
        let seedArtists = (try? await history.topAffinityArtists(forStation: config.id, limit: 3)) ?? []
        if !seedArtists.isEmpty {
            var similarSeen = Set<String>()
            var added = 0
            for seedArtist in seedArtists {
                let neighbours = (try? await client.similarArtists(to: seedArtist, limit: 6)) ?? []
                for neighbour in neighbours {
                    guard similarSeen.insert(neighbour.lowercased()).inserted else { continue }
                    let tracks = (try? await client.topTracksForArtist(neighbour, limit: 2)) ?? []
                    for t in tracks {
                        let key = DedupKey(artist: t.artist.lowercased(), title: t.title.lowercased())
                        guard seeds[key] == nil else { continue }
                        let cand = SourceCandidate(
                            artist: t.artist,
                            title: t.title,
                            resolvedURL: nil,
                            listenersHint: t.listeners,
                            matchedTags: requiredTags
                        )
                        seeds[key] = SeedRecord(candidate: cand, matchedTags: requiredTags)
                        added += 1
                    }
                }
            }
            logger.info("stage1b similar-artist: +\(added) candidates from \(seedArtists.count) seed artist(s)")
        }

        if seeds.isEmpty {
            throw Error.noTracksForTags(config.query.genreTags)
        }

        // Stage 2: tag mode (union / intersection) via the shared pipeline.
        let tagModeInput: [(SourceCandidate, Set<String>)] = seeds.values.map { ($0.candidate, $0.matchedTags) }
        var candidates: [SourceCandidate] = FacetedPipeline.applyTagMode(
            tagModeInput,
            required: requiredTags,
            mode: config.query.tagMatch
        )
        logger.info("stage2 tag mode: \(candidates.count) candidates remain")

        // Stage 3: popularity tier split by listener count. Sort desc,
        // then pick the slice that matches the configured tier. Last.fm-
        // specific — Bandcamp has no listener count so this stage doesn't
        // live in the shared pipeline.
        candidates.sort { ($0.listenersHint ?? 0) > ($1.listenersHint ?? 0) }
        let total = candidates.count
        if total > 0 {
            let topCut = max(1, total / 10)           // top 10%
            let midCut = max(topCut + 1, total / 2)   // through 50%
            switch config.query.popularity {
            case .hits:
                candidates = Array(candidates.prefix(topCut))
            case .middle:
                candidates = Array(candidates[topCut..<min(midCut, candidates.count)])
            case .deepCuts:
                candidates = Array(candidates[min(midCut, candidates.count)..<candidates.count])
            }
        }
        logger.info("stage3 popularity \(String(describing: self.config.query.popularity), privacy: .public): \(candidates.count) candidates remain")

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

        // Stage 5: precision verification — artist's top-5 tags must
        // include at least one of the QUERY tags (not a mixed bag that
        // could include decades or regions — that's the Exaltasamba bug
        // the facet split was designed to eliminate). One API call per
        // unique artist; cached in `LastFMClient`. Always runs top-5
        // verified now that the user-facing `.off` knob is gone.
        //
        // Stays in the controller because it's Last.fm-specific — the
        // Bandcamp pipeline has no equivalent top-tags endpoint.
        if !candidates.isEmpty {
            let topN = 5
            let queryTagsLower = requiredTags
            var verified: [SourceCandidate] = []
            for c in candidates {
                do {
                    let tags = try await client.artistTopTags(c.artist)
                    let topTags = Set(tags.prefix(topN).map { $0.name })
                    if !topTags.isDisjoint(with: queryTagsLower) {
                        verified.append(c)
                    } else {
                        logger.info("precision dropped \(c.artist, privacy: .public) (top: \(topTags.sorted().joined(separator: ", "), privacy: .public))")
                    }
                } catch {
                    // Fail-open: if the API call fails, don't over-filter.
                    // Logging at info keeps OSLog from filling with noise.
                    logger.info("artist tag lookup failed for \(c.artist, privacy: .public); keeping: \(String(describing: error), privacy: .public)")
                    verified.append(c)
                }
            }
            candidates = verified
        }
        logger.info("stage5 precision: \(candidates.count) candidates remain")

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
        // (skipped) candidates and sort the rest high→low. Reads matched
        // tags directly from the candidate — no side-table lookup needed
        // now that tags ride along with the SourceCandidate.
        var scored: [(cand: SourceCandidate, score: Double)] = []
        for c in candidates {
            let s = await tasteProfile.score(
                candidateArtist: c.artist,
                candidateTags: Array(c.matchedTags),
                stationID: config.id,
                history: history,
                exploration: config.exploration
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

        // Stage 9: wildcard reservation. Split the survivors: top (1 -
        // wildcardFraction) by score, then (wildcardFraction) random
        // picks from the rest. Shuffle each half and interleave so the
        // encode loop sees rotating variety instead of a ranked block.
        // Explore dial widens the wildcard share: comfort (0) keeps the
        // baseline 20%, full explore (1) pushes it to 60% so novelty leads.
        let effectiveWildcard = min(0.8, wildcardFraction + config.exploration * 0.4)
        let wildcardCount = max(1, Int(Double(scored.count) * effectiveWildcard))
        let topCount = max(0, scored.count - wildcardCount)
        let topSlice = Array(scored.prefix(topCount)).map { $0.cand }
        var wildcardSlice = Array(scored.suffix(wildcardCount)).map { $0.cand }
        wildcardSlice.shuffle()

        pool = interleave(topSlice, wildcardSlice)
        if config.shufflePool {
            // Mild final shuffle within 4-track windows so the first
            // couple of plays aren't always the single top-scored pick.
            pool = softShuffle(pool, window: 4)
        }
        cursor = 0
        logger.info("stage9 pool ready: \(self.pool.count) candidates (wildcards: \(wildcardCount))")
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
