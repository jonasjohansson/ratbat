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
/// - ``TrackResolver`` turns a candidate into a cached audio file. For
///   Bandcamp sources it takes the direct-URL shortcut — every candidate
///   here carries ``SourceCandidate/resolvedURL``, so the resolver hands
///   that URL straight to yt-dlp's `BandcampIE` extractor and skips the
///   YouTube-Music search. No Ratbat-side scraping beyond the discover
///   endpoint is involved in the download path.
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
        /// The Bandcamp release page this track came from. Always present:
        /// the stage-1 discover scrape hands us a release URL for every
        /// candidate, which is also what makes the direct-URL resolver
        /// shortcut possible.
        public let sourceURL: URL
        /// Display metadata from the extractor. Bandcamp's yt-dlp
        /// extractor is generous here — album, duration and release art
        /// are all normally present.
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

    private let config: BandcampStationConfig
    private let client: BandcampClient
    private let musicBrainz: MusicBrainzClient
    private let history: HistoryStore
    private let resolver: TrackResolver
    private let tasteProfile: TasteProfile
    private let logger = Logger(subsystem: RatbatLog.subsystem, category: "bandcamp-station")

    /// `source_kind` stamped on this station's exclusion rows.
    private static let sourceKind = "bandcamp"

    /// What ``BandcampRelease/featuredTrackDurationSeconds`` reported for a
    /// candidate. A side table rather than a new field on
    /// ``SourceCandidate``: that type is shared with the Last.fm and NTS
    /// controllers, neither of which has a duration to put in it.
    /// Rebuilt on each refill.
    private var durationByCandidate: [DedupKey: TimeInterval] = [:]

    /// Live read of the listener's two dials. A provider, not a value:
    /// ``BroadcastPreferences`` is `@MainActor` and this is an actor, and a
    /// policy snapshotted at construction would be frozen for the whole
    /// broadcast. Re-read at every pool refill.
    private let selectionPolicy: @Sendable () async -> SelectionPolicy

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
        tasteProfile: TasteProfile,
        selectionPolicy: @escaping @Sendable () async -> SelectionPolicy = { .default }
    ) {
        self.config = config
        self.client = client
        self.musicBrainz = musicBrainz
        self.history = history
        self.resolver = resolver
        self.tasteProfile = tasteProfile
        self.selectionPolicy = selectionPolicy
    }

    // MARK: - Public

    /// Produce the next resolved track for this station.
    ///
    /// Mirrors ``LastFMStationController/nextTrack()``: skips candidates
    /// already in history, skips candidates with no YouTube match or
    /// transient resolver failures, refills the pool when empty, caps
    /// the retry loop at `maxAttempts` so a bad stretch can't hang.
    public func nextTrack() async throws -> ResolvedTrack {
        // A dial moved since this pool was built? Re-choose from what is
        // left instead of waiting for the pool to drain — a Bandcamp pool
        // is the deepest of the three and can take a long time to turn over.
        await reapplyPolicyIfChanged()

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
                // Direct-URL shortcut (Task 10): the resolver branches
                // internally on ``SourceCandidate/resolvedURL``. When that
                // field is set — which our stage-1 scrape guarantees for
                // every Bandcamp candidate — the resolver hands the URL
                // straight to yt-dlp's `BandcampIE` extractor, skipping
                // the YouTube-Music search entirely. ``Resolution/youtubeID``
                // in that case is a synthetic `"bandcamp:<id>"` identifier,
                // not a real YT catalog id.
                let resolution = try await resolver.resolve(candidate: candidate)
                // Prefer the Bandcamp release URL when we have it so the
                // history row points at the actual source page (useful
                // for "where did this come from?" debugging) rather than
                // a synthetic YT-Music fallback. For direct-URL results
                // the fallback wouldn't resolve to a playable YT page
                // anyway — its id is a `"bandcamp:..."` sentinel.
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
                    sourceURL: sourceURL,
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
        durationByCandidate.removeAll(keepingCapacity: true)
        for tag in config.query.genreTags {
            do {
                let releases = try await client.releases(forTag: tag, sort: config.sort)
                indexDurations(releases)
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
            poolPolicy = nil
            throw Error.noTracksForTags(config.query.genreTags)
        }

        // Stage 9: wildcard reservation + optional shuffle. Honors
        // `config.shufflePool`: false preserves the scrape-order, which
        // matters when `sort: .date` is picked — the user asked for
        // "newest first", so we ship newest first. True mixes a top /
        // wildcard interleave plus a soft in-window shuffle so the
        // station doesn't always lead with the same top-scored pick.
        let ranked: [SourceCandidate]
        if config.shufflePool {
            let wildcardCount = max(1, Int(Double(scored.count) * wildcardFraction))
            let topCount = max(scored.count - wildcardCount, 0)
            let topSlice = Array(scored.prefix(topCount)).map { $0.cand }
            var wildcardSlice = Array(scored.suffix(wildcardCount)).map { $0.cand }
            wildcardSlice.shuffle()

            ranked = softShuffle(interleave(topSlice, wildcardSlice), window: 4)
            logger.info("stage9 ranked: \(ranked.count) candidates (wildcards: \(wildcardCount))")
        } else {
            // Temporal mode: keep the scrape order intact. Skip blacklist
            // already applied via stage 8's score-filter.
            ranked = scored.map { $0.cand }
            logger.info("stage9 ranked: \(ranked.count) candidates (order preserved)")
        }

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

    /// Index the featured-track durations the discover listing reported.
    private func indexDurations(_ releases: [BandcampRelease]) {
        for r in releases {
            guard let seconds = r.featuredTrackDurationSeconds else { continue }
            durationByCandidate[
                DedupKey(artist: r.artist.lowercased(), title: r.title.lowercased())
            ] = seconds
        }
    }

    /// What the mix-set rule gets to see about a candidate.
    ///
    /// The duration here is the length of the release's FEATURED TRACK, and
    /// the candidate is the release. Those are not the same thing: the
    /// discover endpoint returns albums almost exclusively (48/48 items of
    /// the `bandcamp-discover-techno` fixture are `type: "a"`), the title
    /// this station plays is the release title, and 4 of those 48 exceed
    /// the 20-minute threshold on the featured track alone. So when this
    /// arm fires it removes a whole release on the strength of one track's
    /// length. That is a real, unmitigated over-reach — this arm is not
    /// conservative and must not be described as such.
    ///
    /// `duration_source` is `listing-featured-track`, never `listing`, so
    /// a reader of the audit log can tell what was measured apart from what
    /// was dropped.
    private func selectionSubject(for candidate: SourceCandidate) -> SelectionSubject {
        let key = DedupKey(
            artist: candidate.artist.lowercased(),
            title: candidate.title.lowercased()
        )
        let seconds = durationByCandidate[key]
        return SelectionSubject(
            artist: candidate.artist,
            title: candidate.title,
            durationSeconds: seconds,
            durationSource: seconds == nil ? nil : "listing-featured-track",
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

    internal func indexDurationsForTesting(_ releases: [BandcampRelease]) {
        indexDurations(releases)
    }

    internal func selectionSubjectForTesting(_ candidate: SourceCandidate) -> SelectionSubject {
        selectionSubject(for: candidate)
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
