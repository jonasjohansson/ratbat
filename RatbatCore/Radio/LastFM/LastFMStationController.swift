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
        /// Too many resolves failed for reasons that say nothing about
        /// the pool — timeouts, download failures, an unreachable network.
        /// Deliberately distinct from ``poolExhausted``: the station has
        /// not run out of music, the machine is having a moment.
        case transientResolveFailure(count: Int)

        /// Whether this error means the station is genuinely over.
        ///
        /// Only end-of-supply qualifies. A transient failure must stay an
        /// error so the encode loop retries it, instead of collapsing to
        /// `nil` at the source layer and being read as "station over".
        public var endsStation: Bool {
            switch self {
            case .poolExhausted, .noTracksForTags: return true
            case .transientResolveFailure: return false
            case .resolveFailed: return true
            }
        }
    }

    private let config: LastFMStationConfig
    private let client: LastFMClient
    private let musicBrainz: MusicBrainzClient
    private let history: HistoryStore
    private let resolver: TrackResolver
    private let tasteProfile: TasteProfile
    private let logger = Logger(subsystem: RatbatLog.subsystem, category: "lastfm-station")

    /// `source_kind` stamped on this station's exclusion rows.
    private static let sourceKind = "lastfm"

    /// Live read of the listener's two dials. A provider, not a value:
    /// ``BroadcastPreferences`` is `@MainActor` and this is an actor, and a
    /// policy snapshotted at construction would be frozen for the whole
    /// broadcast. Re-read at every pool refill.
    private let selectionPolicy: @Sendable () async -> SelectionPolicy

    /// Boost steering's seed override — artists the owner just boosted,
    /// read fresh at every refill and placed at the FRONT of the
    /// similar-artist expansion queue. A provider for the same reason
    /// `selectionPolicy` is: the overrides live on the main-actor
    /// broadcaster (which drains them consume-once), and a value
    /// snapshotted at construction could never steer. The interaction
    /// with ``HistoryStore/topAffinityArtists`` is self-healing — a
    /// boosted artist earns weight-10 rank there, so the override is a
    /// fast path for the very next refill, not a fork.
    private let seedOverride: @Sendable () async -> [String]

    /// Set by ``requestReseed()`` when a boost lands; the next
    /// `nextTrack()` rebuilds the pool instead of draining the stale one.
    private var pendingReseed = false

    private var pool: [SourceCandidate] = []
    private var cursor: Int = 0

    /// The policy the current ``pool`` was built under, so a dial that has
    /// not moved cannot trigger a re-filter.
    private var poolPolicy: SelectionPolicy?

    /// Owned-artist keys captured at the last refill — read by both the
    /// dial's ordering and the phase counters, so the two cannot disagree.
    private var ownedArtistKeys: Set<String> = []

    /// Plays realised on this station, carried into the next refill so
    /// candidates rejected after ordering self-correct rather than drift.
    private var playedNew = 0
    private var playedTotal = 0

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
        tasteProfile: TasteProfile,
        selectionPolicy: @escaping @Sendable () async -> SelectionPolicy = { .default },
        seedOverride: @escaping @Sendable () async -> [String] = { [] }
    ) {
        self.config = config
        self.client = client
        self.musicBrainz = musicBrainz
        self.history = history
        self.resolver = resolver
        self.tasteProfile = tasteProfile
        self.selectionPolicy = selectionPolicy
        self.seedOverride = seedOverride
    }

    // MARK: - Public

    /// Boost steering's entry point: mark the pool stale. The actual
    /// refill waits for the next ``nextTrack()`` call so steering can
    /// never yank the track that is on air — "stations mid-track finish
    /// the track" (signal-model design §3).
    public func requestReseed() {
        pendingReseed = true
    }

    /// Produce the next resolved track for this station.
    ///
    /// Mirrors ``NTSStationController/nextTrack()``: skips candidates
    /// already in history, skips candidates with no YouTube match or
    /// transient resolver failures, refills the pool when empty, caps
    /// the retry loop at `maxAttempts` so a bad stretch can't hang.
    public func nextTrack() async throws -> ResolvedTrack {
        // A dial moved since this pool was built? Re-choose from what is
        // left instead of waiting for the pool to drain.
        await reapplyPolicyIfChanged()

        // A boost landed since this pool was built? Rebuild it with the
        // boosted artist leading the expansion, instead of serving out
        // the remainder of a pool that predates the steering gesture.
        try await refillIfReseedPending()

        // Two budgets, deliberately separate. `attempts` counts candidates
        // the resolver genuinely cannot use; `transientFailures` counts
        // times the machine or network was having a moment. Sharing one
        // budget is what let a network blip masquerade as an empty pool
        // and take the station off air.
        let maxAttempts = 30
        let maxTransientFailures = 8
        var attempts = 0
        var transientFailures = 0

        while attempts < maxAttempts, transientFailures < maxTransientFailures {

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
            if seen { attempts += 1; continue }

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
                // Irreversible commit point: this track is about to play,
                // so it counts toward the dial's realised ratio. Same owned
                // key set the ordering used.
                playedTotal += 1
                if !ownedArtistKeys.contains(SelectionOrdering.artistKey(candidate.artist)) {
                    playedNew += 1
                }
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
                attempts += 1
                continue
            } catch {
                logger.error("resolve failed for \(candidate.artist, privacy: .public) — \(candidate.title, privacy: .public): \(String(describing: error), privacy: .public)")
                // Cancellation is the app shutting us down, not a
                // resolve problem — it must propagate, not be counted.
                if error is CancellationError { throw error }
                switch classifyResolveFailure(error) {
                case .genuine: attempts += 1
                case .transient: transientFailures += 1
                }
                continue
            }
        }

        // Which budget ran out decides what this means. Only a spent
        // candidate budget is "the pool is empty".
        if transientFailures >= maxTransientFailures {
            throw Error.transientResolveFailure(count: transientFailures)
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
    /// Consume a pending boost-reseed request, if any. Split out of
    /// ``nextTrack()`` so the reseed contract — one flag, one refill,
    /// flag cleared even if the refill throws — is testable without
    /// driving the resolver loop.
    internal func refillIfReseedPending() async throws {
        guard pendingReseed else { return }
        // Cleared BEFORE the refill: a refill that throws must not leave
        // the flag set, or every subsequent nextTrack() would re-throw a
        // stale failure instead of retrying on its own schedule.
        pendingReseed = false
        try await refillPool()
    }

    /// Stage 1b's seed ordering, as a pure function: boost overrides go
    /// to the front of the similar-artist expansion queue, affinity seeds
    /// follow, duplicates collapse case-insensitively (first spelling
    /// wins) and the total is capped so a refill can't blow the Last.fm
    /// rate budget.
    nonisolated internal static func mergeSeedArtists(
        overrides: [String],
        affinity: [String],
        cap: Int = 4
    ) -> [String] {
        var merged: [String] = []
        for artist in overrides + affinity {
            let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !merged.contains(where: {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }) else { continue }
            merged.append(trimmed)
        }
        return Array(merged.prefix(cap))
    }

    // Internal, not private: the reseed tests drive a refill directly
    // (the NTSStationController precedent) rather than through the
    // resolver loop, which would need a live Python subprocess.
    internal func refillPool() async throws {
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
        // Boost overrides lead the queue; station affinity fills in
        // behind them. See ``mergeSeedArtists`` for the ordering rules.
        let overrides = await seedOverride()
        let affinitySeeds = (try? await history.topAffinityArtists(forStation: config.id, limit: 3)) ?? []
        let seedArtists = Self.mergeSeedArtists(overrides: overrides, affinity: affinitySeeds)
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
            poolPolicy = nil
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

        var ranked = interleave(topSlice, wildcardSlice)
        if config.shufflePool {
            // Mild final shuffle within 4-track windows so the first
            // couple of plays aren't always the single top-scored pick.
            ranked = softShuffle(ranked, window: 4)
        }
        logger.info("stage9 ranked: \(ranked.count) candidates (wildcards: \(wildcardCount))")

        // Stage 10: the listener's two dials, applied while the pool is
        // being BUILT rather than after a track has already been chosen.
        await applySelectionPolicy(to: ranked)
    }

    // MARK: - Selection policy (stage 10)

    private func applySelectionPolicy(to ranked: [SourceCandidate]) async {
        let policy = await selectionPolicy()
        // ONE actor hop per refill, not one await per candidate.
        ownedArtistKeys = await tasteProfile.ownedArtistKeys()

        let plan = SelectionPlanner.plan(
            ranked.map { SelectionInput(candidate: $0, subject: selectionSubject(for: $0)) },
            policy: policy,
            phase: (new: playedNew, total: playedTotal),
            sourceKind: Self.sourceKind,
            ownedArtistKeys: ownedArtistKeys,
            subject: { $0.subject }
        )

        pool = plan.ordered.map(\.candidate)
        cursor = 0
        // Set at the END of the refill, not only in the re-filter branch:
        // a stale value makes the next nextTrack() re-filter a pool that
        // was just built and double-count hit_count on every candidate.
        poolPolicy = policy
        logger.info("stage10 policy: \(self.pool.count) candidates (exclusions: \(plan.exclusions.count), shortfall: \(plan.shortfall))")
        await record(plan.exclusions)
    }

    /// Re-applies the policy to the UNPLAYED remainder when a dial moved
    /// since this pool was built. No-op when it did not.
    private func reapplyPolicyIfChanged() async {
        guard let built = poolPolicy, cursor < pool.count else { return }
        let policy = await selectionPolicy()
        guard built != policy else { return }

        let remainder = Array(pool[cursor...])
        let plan = SelectionPlanner.plan(
            remainder.map { SelectionInput(candidate: $0, subject: selectionSubject(for: $0)) },
            policy: policy,
            phase: (new: playedNew, total: playedTotal),
            sourceKind: Self.sourceKind,
            ownedArtistKeys: ownedArtistKeys,
            subject: { $0.subject }
        )
        pool = Array(pool[..<cursor]) + plan.ordered.map(\.candidate)
        poolPolicy = policy
        logger.info("policy changed mid-pool: \(remainder.count) → \(plan.ordered.count) remaining")
        await record(plan.exclusions)
    }

    /// What the mix-set rule gets to see about a candidate.
    ///
    /// The duration is always nil, and not defensively so: Last.fm's API
    /// surface has no duration field at all — ``LastFMClient/TrackCandidate``
    /// is `(artist, title, listeners, playcount)` and nothing downstream
    /// adds one before the track is chosen. This is a title-arm-only
    /// source, with nothing to corroborate the word list.
    private func selectionSubject(for candidate: SourceCandidate) -> SelectionSubject {
        SelectionSubject(
            artist: candidate.artist,
            title: candidate.title,
            durationSeconds: nil,
            durationSource: nil,
            sourceURL: candidate.resolvedURL
        )
    }

    private func record(_ rows: [SelectionExclusionRecord]) async {
        guard !rows.isEmpty else { return }
        do {
            try await history.recordExclusions(
                rows.map(HistoryStore.ExclusionInput.init),
                stationID: config.id
            )
        } catch {
            // Best-effort: the audit log must never take the station down.
            logger.error("failed to record selection exclusions: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Test seams

    internal func selectionSubjectForTesting(_ candidate: SourceCandidate) -> SelectionSubject {
        selectionSubject(for: candidate)
    }

    internal func poolSnapshot() -> [SourceCandidate] { pool }

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
