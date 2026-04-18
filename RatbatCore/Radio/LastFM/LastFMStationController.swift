#if os(macOS)
import Foundation
import OSLog

/// Orchestrator that turns a ``LastFMStationConfig`` into a stream of
/// playable, cached tracks — the Last.fm counterpart to
/// ``NTSStationController``.
///
/// Glue between four actors:
/// - ``LastFMClient`` supplies the raw candidate pool via
///   `tag.getTopTracks` and the per-artist top-tag list used by the
///   precision filter.
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
/// The pool is refilled from Last.fm with a five-stage pipeline: raw
/// fetch → tag-mode union/intersection → popularity tier → library +
/// blacklist exclusions → precision verification → taste scoring →
/// wildcard reservation. Each stage logs the surviving candidate count
/// so a suspicious drop (e.g. precision=strict knocking out the whole
/// pool) is obvious in OSLog.
public actor LastFMStationController {

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

    private let config: LastFMStationConfig
    private let client: LastFMClient
    private let history: HistoryStore
    private let resolver: TrackResolver
    private let tasteProfile: TasteProfile
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "lastfm-station")

    private var pool: [LastFMClient.TrackCandidate] = []
    private var cursor: Int = 0

    /// Reservation ratio: what fraction of the pool is unscored wildcards
    /// vs taste-sorted top picks. 0.2 = 20% wildcards, matches the design
    /// doc. Kept as a constant until we see a reason to expose it.
    private let wildcardFraction: Double = 0.2

    public init(
        config: LastFMStationConfig,
        client: LastFMClient,
        history: HistoryStore,
        resolver: TrackResolver,
        tasteProfile: TasteProfile
    ) {
        self.config = config
        self.client = client
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
        // Stage 1: raw fetch per configured tag. Aggregated into a
        // `tagHits` map so tag-mode union/intersection is one scan.
        var tagHits: [DedupKey: TagHitRecord] = [:]
        for tag in config.tags {
            do {
                let tracks = try await client.topTracks(forTag: tag, limit: 200)
                for t in tracks {
                    let key = DedupKey(artist: t.artist.lowercased(), title: t.title.lowercased())
                    var hit = tagHits[key] ?? TagHitRecord(candidate: t, matchedTags: [])
                    hit.matchedTags.insert(tag.lowercased())
                    tagHits[key] = hit
                }
            } catch {
                logger.info("topTracks fetch failed for tag \(tag, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if tagHits.isEmpty {
            throw Error.noTracksForTags(config.tags)
        }

        // Stage 2: tag mode (union / intersection).
        let requiredTags = Set(config.tags.map { $0.lowercased() })
        var candidates: [LastFMClient.TrackCandidate] = tagHits.values.compactMap { hit in
            switch config.tagMode {
            case .any:
                return hit.candidate
            case .all:
                return hit.matchedTags.isSuperset(of: requiredTags) ? hit.candidate : nil
            }
        }
        logger.info("stage2 tag mode: \(candidates.count) candidates remain")

        // Stage 3: popularity tier split by listener count. Sort desc,
        // then pick the slice that matches the configured tier.
        candidates.sort { $0.listeners > $1.listeners }
        let total = candidates.count
        if total > 0 {
            let topCut = max(1, total / 10)           // top 10%
            let midCut = max(topCut + 1, total / 2)   // through 50%
            switch config.popularity {
            case .hits:
                candidates = Array(candidates.prefix(topCut))
            case .middle:
                candidates = Array(candidates[topCut..<min(midCut, candidates.count)])
            case .deepCuts:
                candidates = Array(candidates[min(midCut, candidates.count)..<candidates.count])
            }
        }
        logger.info("stage3 popularity \(String(describing: self.config.popularity), privacy: .public): \(candidates.count) candidates remain")

        // Stage 4: library + artist exclusions.
        if config.excludeOwnedLibrary {
            var filtered: [LastFMClient.TrackCandidate] = []
            for c in candidates {
                let owned = await tasteProfile.libraryContainsArtist(c.artist)
                if !owned { filtered.append(c) }
            }
            candidates = filtered
        }
        if !config.excludedArtists.isEmpty {
            let excluded = Set(config.excludedArtists.map { $0.lowercased() })
            candidates = candidates.filter { !excluded.contains($0.artist.lowercased()) }
        }
        logger.info("stage4 exclusions: \(candidates.count) candidates remain")

        // Stage 5: precision mode — verify artist's top tags include at
        // least one of the query tags. Off = skip, verified = top-5,
        // strict = top-3. One API call per unique artist; cached in
        // `LastFMClient`.
        if config.precision != .off && !candidates.isEmpty {
            let topN: Int = (config.precision == .strict) ? 3 : 5
            let queryTagsLower = requiredTags
            var verified: [LastFMClient.TrackCandidate] = []
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

        // Stage 6: skip blacklist + taste scoring. Drop negative-scored
        // (skipped) candidates and sort the rest high→low.
        var scored: [(cand: LastFMClient.TrackCandidate, score: Double)] = []
        for c in candidates {
            let s = await tasteProfile.score(
                candidateArtist: c.artist,
                candidateTags: Array(tagHits[DedupKey(artist: c.artist.lowercased(), title: c.title.lowercased())]?.matchedTags ?? []),
                stationID: config.id,
                history: history
            )
            if s < 0 { continue }     // skip blacklist hit
            scored.append((c, s))
        }
        scored.sort { $0.score > $1.score }
        logger.info("stage6 scored: \(scored.count) candidates ranked")

        if scored.isEmpty {
            pool = []
            cursor = 0
            throw Error.noTracksForTags(config.tags)
        }

        // Stage 7: wildcard reservation. Split the survivors: top (1 -
        // wildcardFraction) by score, then (wildcardFraction) random
        // picks from the rest. Shuffle each half and interleave so the
        // encode loop sees rotating variety instead of a ranked block.
        let wildcardCount = max(1, Int(Double(scored.count) * wildcardFraction))
        let topCount = max(scored.count - wildcardCount, scored.count - wildcardCount)
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
        logger.info("pool ready: \(self.pool.count) candidates (wildcards: \(wildcardCount))")
    }

    // MARK: - Helpers

    private struct TagHitRecord {
        let candidate: LastFMClient.TrackCandidate
        var matchedTags: Set<String>   // lowercased tag names
    }

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
