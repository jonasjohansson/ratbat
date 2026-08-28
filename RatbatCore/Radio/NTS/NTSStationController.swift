#if os(macOS)
import Foundation
import OSLog

/// Orchestrator that turns an ``NTSStationConfig`` into a stream of
/// playable, cached tracks.
///
/// Glue between up to six actors:
/// - ``NTSClient`` supplies the candidate pool via show + tracklist
///   scraping for the configured tags.
/// - ``MusicBrainzClient`` supplies authoritative release-year + country
///   metadata, used by the shared ``FacetedPipeline`` for era + region
///   filtering.
/// - ``LastFMClient`` (optional) supplies per-artist top-tag verification
///   so we can defuse the class of bug where a DJ's "techno" show has
///   jazz/soul interludes — the show is tagged techno, but individual
///   tracks may not be. Without a Last.fm API key the controller
///   degrades to the legacy behaviour (pre-facet filtering only).
/// - ``HistoryStore`` provides per-station dedup + the skip blacklist.
/// - ``TrackResolver`` turns `(artist, title)` into a cached audio file
///   via the shared yt-dlp + YT Music pipeline.
/// - ``TasteProfile`` scores survivors against a locally derived taste
///   profile (library top artists / top tags + per-station ♥-saves).
///
/// ``nextTrack()`` is the only consumer-facing entry point. It pulls the
/// next unseen candidate, resolves it, records the play, and returns a
/// ``ResolvedTrack`` the broadcaster can hand to its decoder.
///
/// ### Pool pipeline
///
/// Unlike the Last.fm / Bandcamp sources — which fetch a big batch
/// upfront — NTS paginates by show. Each refill pulls a small batch of
/// shows (up to 8 per pass), unions their tracklists, then runs the
/// FULL ``FacetedPipeline`` over that batch so the per-track facets are
/// enforced every pool cycle. Batch size is deliberately larger than
/// Last.fm/Bandcamp because NTS's pool is ~20× smaller to start with
/// and the downstream facet filters can chew through it fast:
///
/// - Stage 1: scrape up to 8 shows → build one ``SourceCandidate`` per
///   unique (artist, title) with the show's genres as `matchedTags`.
///   Retains insertion order so the "newest show first" ordering
///   survives when `shufflePool` is off.
/// - Stage 2: tag mode (any / all) via the shared pipeline.
/// - Stage 4: library + artist exclusions via the shared pipeline.
/// - Stage 5 (optional): per-artist top-tag verification through
///   Last.fm. When no API key is configured the stage is skipped and a
///   single info log explains why.
/// - Stage 6 / 7: MB era + region filters via the shared pipeline.
/// - Stage 8: taste scoring + skip blacklist (drop negative scores).
/// - Stage 9: wildcard reservation + optional shuffle.
///
/// Each stage logs surviving cardinality so a suspicious drop is
/// obvious in OSLog.
public actor NTSStationController {

    public struct ResolvedTrack: Sendable {
        public let artist: String
        public let title: String
        public let cachedURL: URL
        public let youtubeID: String
        public let historyID: Int64    // HistoryStore rowid — for later ♥-save
        public let sourceShowURL: URL
        /// Display metadata the resolver's extractor already knew. `nil`
        /// where the extractor didn't report it — an NTS tracklist entry
        /// resolved through YouTube Music often has no album.
        public let album: String?
        public let duration: TimeInterval?
        public let artworkURL: String?
    }

    public enum Error: Swift.Error, Sendable {
        case poolExhausted
        case noShowsForTags([String])
        case noTracklistsAvailable
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
            case .poolExhausted, .noShowsForTags, .noTracklistsAvailable: return true
            case .transientResolveFailure: return false
            case .resolveFailed: return true
            }
        }
    }

    private let config: NTSStationConfig
    private let nts: NTSClient
    private let musicBrainz: MusicBrainzClient
    private let lastFM: LastFMClient?
    private let history: HistoryStore
    private let resolver: TrackResolver
    private let tasteProfile: TasteProfile
    private let logger = Logger(subsystem: RatbatLog.subsystem, category: "nts-station")

    /// `source_kind` stamped on this station's exclusion rows.
    private static let sourceKind = "nts"

    /// Live read of the listener's two dials.
    ///
    /// A provider, not a value. ``BroadcastPreferences`` is `@MainActor`
    /// and this is an actor, so the policy has to cross a boundary — and
    /// crossing it ONCE at construction (the shape every other preference
    /// in this codebase uses) would freeze both settings for the whole
    /// broadcast. It is re-read at every pool refill instead, so moving a
    /// dial mid-broadcast takes effect without a restart.
    private let selectionPolicy: @Sendable () async -> SelectionPolicy

    /// Carries the NTS show-URL for the artist/title pair through the
    /// pipeline — ``SourceCandidate`` has no such field, but we need it
    /// when recording history so "where did this come from?" is
    /// answerable. Rebuilt on each refill; lookups are case-insensitive
    /// on (artist, title) so casing drift between `matchedTags` copies
    /// and the candidate out the back of the pipeline doesn't matter.
    private var showURLByCandidate: [DedupKey: URL] = [:]

    /// Track duration for the artist/title pair, when NTS supplies one.
    /// It currently never does — the tracklist API's `duration` key is
    /// null on every row we have sampled — so this side table is expected
    /// to stay empty and the mix-set title arm carries the entire load on
    /// this source. Wired anyway so the duration arm starts working the
    /// day NTS populates the field. Rebuilt each refill, like the show URLs.
    private var durationByCandidate: [DedupKey: TimeInterval] = [:]

    /// Survivors of the last pipeline pass.
    private var pool: [SourceCandidate] = []
    private var cursor: Int = 0

    /// The policy the current ``pool`` was built under, so a dial that has
    /// not moved cannot trigger a re-filter.
    private var poolPolicy: SelectionPolicy?

    /// Owned-artist keys captured at the last refill. The dial's ordering
    /// and the phase counters below both read THIS set, so ownership can
    /// not be judged one way when ordering and another way when counting.
    private var ownedArtistKeys: Set<String> = []

    /// Plays realised on this station: `playedNew` of `playedTotal` were by
    /// artists the owner has nothing by. Fed into the next refill so
    /// candidates rejected AFTER ordering — already played, resolve failed
    /// — are corrected for instead of accumulating as permanent drift.
    private var playedNew = 0
    private var playedTotal = 0

    /// Cached list of shows matching the station's tags. We drain up to
    /// eight shows per pool refill so NTS isn't hammered on every single
    /// `nextTrack()` call and so the pipeline has a healthy batch to
    /// work with.
    private var shows: [NTSClient.Show] = []
    private var showCursor: Int = 0

    /// Reservation ratio: what fraction of the pool is unscored wildcards
    /// vs taste-sorted top picks. 0.2 matches the Last.fm / Bandcamp
    /// controllers so all three generative stations behave consistently.
    private let wildcardFraction: Double = 0.2

    public init(
        config: NTSStationConfig,
        nts: NTSClient,
        musicBrainz: MusicBrainzClient,
        lastFM: LastFMClient?,
        history: HistoryStore,
        resolver: TrackResolver,
        tasteProfile: TasteProfile,
        selectionPolicy: @escaping @Sendable () async -> SelectionPolicy = { .default }
    ) {
        self.config = config
        self.nts = nts
        self.musicBrainz = musicBrainz
        self.lastFM = lastFM
        self.history = history
        self.resolver = resolver
        self.tasteProfile = tasteProfile
        self.selectionPolicy = selectionPolicy
    }

    // MARK: - Test seams

    /// Substitute resolution so the pool/budget logic can be exercised
    /// without a Python subprocess or the live YouTube Music catalogue.
    ///
    /// Follows the `selectionPolicy` closure this type already takes: the
    /// alternative is that `nextTrack()` — where a station decides whether
    /// it is still alive — stays untestable, which is how a counter bug
    /// took a station off air unnoticed.
    internal var resolveOverride: (@Sendable (String, String) async throws -> TrackResolver.Resolution)?

    /// Seed the pool directly, bypassing the NTS scrape.
    internal func seedPoolForTesting(_ candidates: [SourceCandidate]) {
        pool = candidates
        cursor = 0
    }

    internal func setResolveOverrideForTesting(
        _ fn: @escaping @Sendable (String, String) async throws -> TrackResolver.Resolution
    ) {
        resolveOverride = fn
    }

    /// The station id `history` rows are keyed on.
    internal var stationIDForTesting: UUID { config.id }

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
        // Has a dial moved since this pool was built? Re-choose from what
        // is left rather than waiting for the pool to drain — "I turned it
        // off and nothing happened" is the complaint this prevents.
        await reapplyPolicyIfChanged()

        // Two budgets, deliberately separate. `attempts` counts candidates
        // the resolver genuinely cannot use; `transientFailures` counts
        // times the machine or network was having a moment. Sharing one
        // budget is what let a network blip masquerade as an empty pool
        // and take the station off air.
        let maxAttempts = 30
        let maxTransientFailures = 8
        // Pool traversals allowed in one call. Refilling resets `cursor` to
        // 0, so without a bound a pool that is entirely already-played would
        // re-walk itself forever. Each refill drains up to 8 more shows, so
        // four is a meaningful amount of new supply before concluding there
        // is none.
        let maxRefills = 4
        var attempts = 0
        var transientFailures = 0
        var refills = 0
        // Counted but NOT budgeted — see below. Kept for the log line on the
        // way out, because when this station folded the logs said only
        // "exhausted" and gave no way to tell a spent pool from a spent
        // counter.
        var alreadyPlayed = 0

        while attempts < maxAttempts, transientFailures < maxTransientFailures {

            if cursor >= pool.count {
                guard refills < maxRefills else { break }
                refills += 1
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
            // Deliberately does NOT spend the candidate budget.
            //
            // It used to. `attempts` was one counter for "this candidate is
            // unusable" and "we have played this already", and the second is
            // not evidence of anything — it is the normal state of every
            // track a station has ever played. NTS Techno had 28 plays and
            // two tracks the resolver could not match: 28 + 2 = 30 =
            // maxAttempts, so it threw poolExhausted on the FIRST track of
            // every run, surfaced as `nil`, and the station went off air and
            // vanished from now.json. The website showed it offline.
            //
            // The bug scaled with success: every station folds once its play
            // count reaches the cap. NTS Disco only escaped because it has
            // `shufflePool: true`, so a reshuffle kept finding unplayed
            // tracks before the counter ran out.
            //
            // Termination does not depend on this counter: each iteration
            // advances `cursor`, and pool traversals are bounded by
            // `maxRefills`.
            if seen { alreadyPlayed += 1; continue }

            let dedup = DedupKey(
                artist: candidate.artist.lowercased(),
                title: candidate.title.lowercased()
            )
            // Fall back to an NTS base URL if the side-table lookup
            // misses — shouldn't happen in practice, but history.record
            // needs a non-optional URL and we'd rather log a synthetic
            // than crash on a stale pool entry.
            let sourceShowURL = showURLByCandidate[dedup]
                ?? URL(string: "https://www.nts.live/")!

            do {
                let resolution: TrackResolver.Resolution
                if let resolveOverride {
                    resolution = try await resolveOverride(candidate.artist, candidate.title)
                } else {
                    resolution = try await resolver.resolve(
                        artist: candidate.artist,
                        title: candidate.title
                    )
                }
                let rowid = try await history.record(
                    station: config.id,
                    artist: candidate.artist,
                    title: candidate.title,
                    sourceShowURL: sourceShowURL,
                    youtubeID: resolution.youtubeID,
                    cachedPath: resolution.cachedURL.path
                )
                logger.info("resolved \(candidate.artist, privacy: .public) — \(candidate.title, privacy: .public)")
                // Irreversible commit point: this track is about to play,
                // so it counts toward the dial's realised ratio. Read from
                // the SAME owned key set the ordering used.
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
                    sourceShowURL: sourceShowURL,
                    album: resolution.album,
                    duration: resolution.duration,
                    artworkURL: resolution.artworkURL
                )
            } catch TrackResolver.Error.noYouTubeMatch {
                // Don't record — if the YT catalog adds a match later
                // we'd rather play it than carry a silent skip forward.
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
        // Say which budget ran out. "exhausted" alone was undiagnosable:
        // it could not distinguish an empty pool from a spent counter.
        logger.notice(
            """
            pool exhausted for \(self.config.name, privacy: .public): \
            \(attempts, privacy: .public) unusable candidates, \
            \(alreadyPlayed, privacy: .public) already played, \
            \(refills, privacy: .public) refills, pool \(self.pool.count, privacy: .public)
            """
        )
        throw Error.poolExhausted
    }

    // MARK: - Pool pipeline

    /// Drain the next batch of NTS shows, collapse their tracklists into
    /// a ``SourceCandidate`` list, then run the full faceted pipeline.
    internal func refillPool() async throws {
        if showCursor >= shows.count {
            try await refreshShows()
        }
        guard showCursor < shows.count else {
            throw Error.noShowsForTags(config.query.genreTags)
        }

        // Stage 1: scrape. Drain up to 8 shows, fold duplicate
        // (artist, title) pairs into a single SourceCandidate with the
        // accumulated show genres as `matchedTags`.
        //
        // Preserve first-insertion order — dictionary iteration is
        // non-deterministic (randomised hash seeding) which would
        // reshuffle the pool on every refill and fight `shufflePool =
        // false`.
        struct SeedRecord {
            var candidate: SourceCandidate
            var matchedTags: Set<String>
            var showURL: URL
            var durationSeconds: TimeInterval?
        }
        var seeds: [SeedRecord] = []
        var seedIndex: [DedupKey: Int] = [:]

        let take = min(8, shows.count - showCursor)
        for _ in 0..<take {
            let show = shows[showCursor]
            showCursor += 1
            do {
                var listings = try await nts.tracklist(for: show.url)
                if config.shufflePool {
                    listings.shuffle()
                }
                // Show-level genres double as each tracklisting's
                // matchedTags — the show is the unit of tag curation on
                // NTS. Lowercased to match FacetedPipeline conventions.
                let showTagsLower = Set(show.tags.map { $0.lowercased() })
                for row in listings {
                    let key = DedupKey(
                        artist: row.artist.lowercased(),
                        title: row.title.lowercased()
                    )
                    if let idx = seedIndex[key] {
                        var existing = seeds[idx]
                        existing.matchedTags.formUnion(showTagsLower)
                        existing.candidate = SourceCandidate(
                            artist: existing.candidate.artist,
                            title: existing.candidate.title,
                            resolvedURL: existing.candidate.resolvedURL,
                            listenersHint: existing.candidate.listenersHint,
                            matchedTags: existing.matchedTags
                        )
                        seeds[idx] = existing
                    } else {
                        let cand = SourceCandidate(
                            artist: row.artist,
                            title: row.title,
                            resolvedURL: nil,
                            listenersHint: nil,
                            matchedTags: showTagsLower
                        )
                        seedIndex[key] = seeds.count
                        seeds.append(SeedRecord(
                            candidate: cand,
                            matchedTags: showTagsLower,
                            showURL: show.url,
                            durationSeconds: row.durationSeconds
                        ))
                    }
                }
            } catch {
                logger.info("skip show with unfetchable tracklist: \(show.url.absoluteString, privacy: .public)")
            }
        }

        if seeds.isEmpty {
            throw Error.noTracklistsAvailable
        }
        logger.info("stage1 scrape: \(seeds.count) candidates from \(take) show(s)")

        // Rebuild the show-URL side-table so history.record can source
        // the original NTS page.
        showURLByCandidate.removeAll(keepingCapacity: true)
        durationByCandidate.removeAll(keepingCapacity: true)
        for seed in seeds {
            let key = DedupKey(
                artist: seed.candidate.artist.lowercased(),
                title: seed.candidate.title.lowercased()
            )
            showURLByCandidate[key] = seed.showURL
            if let seconds = seed.durationSeconds {
                durationByCandidate[key] = seconds
            }
        }

        // Stage 2: tag mode via the shared pipeline. `.any` is a no-op
        // here — NTS tags are show-level, not Last.fm's global cloud,
        // so every candidate already matched SOME required tag just by
        // surviving the per-tag show scrape. `.all` narrows to
        // candidates whose parent show was tagged with every required
        // tag simultaneously.
        let requiredTags = Set(config.query.genreTags.map { $0.lowercased() })
        let tagModeInput: [(SourceCandidate, Set<String>)] = seeds.map { ($0.candidate, $0.matchedTags) }
        var candidates: [SourceCandidate] = FacetedPipeline.applyTagMode(
            tagModeInput,
            required: requiredTags,
            mode: config.query.tagMatch
        )
        logger.info("stage2 tag mode: \(candidates.count) candidates remain")

        // Stage 3: popularity tier — SKIPPED for NTS. There is no
        // listener-count signal (DJ-curated, not aggregated); popularity
        // doesn't translate.

        // Stage 4: library + artist exclusions via the shared pipeline.
        // Runs BEFORE the network-expensive stages so we don't spend
        // HTTP budget on candidates we're about to drop anyway.
        candidates = await FacetedPipeline.applyExclusions(
            candidates,
            excludedArtists: config.query.excludedArtists,
            excludeOwnedLibrary: config.query.excludeOwnedLibrary,
            tasteProfile: tasteProfile
        )
        logger.info("stage4 exclusions: \(candidates.count) candidates remain")

        // Stage 5: optional precision verification through Last.fm.
        //
        // This is the whole reason NTS moved onto the shared pipeline:
        // a DJ's "techno" show can include jazz or soul interludes. The
        // SHOW is tagged techno, but the individual tracks aren't.
        // Without precision, those interludes leak into a "techno"
        // station's feed.
        //
        // When the user has a Last.fm API key configured we check each
        // candidate artist's top-10 tags against the station's required
        // tags and drop misses. Top-10 (vs Last.fm's top-5) is
        // intentionally more lenient because NTS's pool is ~20× smaller
        // to start with — strict top-5 over 60 candidates could easily
        // filter to zero, while top-10 keeps genre-adjacent artists
        // (e.g. techno tagged "electronic"/"minimal" but not "techno"
        // in the top 5) in the pool. When no key is present the stage
        // is skipped and we log once so the reason for the drop-off in
        // specificity is discoverable without reading source.
        if let lastFM, !candidates.isEmpty {
            let topN = 10
            let queryTagsLower = requiredTags
            var verified: [SourceCandidate] = []
            // Per-refill cache so repeated artists don't trigger a
            // second Last.fm call. LastFMClient has its own actor-
            // scoped cache too, but this keeps the hot path bounded.
            var artistTagCache: [String: Set<String>] = [:]
            for c in candidates {
                let key = c.artist.lowercased()
                let topTags: Set<String>
                if let cached = artistTagCache[key] {
                    topTags = cached
                } else {
                    do {
                        let tags = try await lastFM.artistTopTags(c.artist)
                        topTags = Set(tags.prefix(topN).map { $0.name })
                        artistTagCache[key] = topTags
                    } catch {
                        // Fail-open: if the API call fails, keep the
                        // candidate rather than over-filter. Logged at
                        // info so OSLog doesn't fill with noise.
                        logger.info("precision lookup failed for \(c.artist, privacy: .public); keeping: \(String(describing: error), privacy: .public)")
                        verified.append(c)
                        continue
                    }
                }
                if !topTags.isDisjoint(with: queryTagsLower) {
                    verified.append(c)
                } else {
                    logger.info("precision dropped \(c.artist, privacy: .public) (top: \(topTags.sorted().joined(separator: ", "), privacy: .public))")
                }
            }
            candidates = verified
        } else if lastFM == nil {
            logger.info("stage5 precision: skipped — Last.fm key not set")
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
        // (skipped) candidates and sort the rest high→low.
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
            // Pipeline drained the batch entirely. The outer refill loop
            // will call refillPool again on the next nextTrack(), which
            // advances showCursor to the next batch. Let that ride
            // rather than pre-draining recursively here.
            pool = []
            cursor = 0
            poolPolicy = nil
            throw Error.noTracklistsAvailable
        }

        // Stage 9: wildcard reservation + optional shuffle. Mirrors
        // LastFM/Bandcamp so the three generative stations feel
        // consistent. When `shufflePool` is off we keep scrape order
        // (newest show first), skipping the wildcard split.
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
            ranked = scored.map { $0.cand }
            logger.info("stage9 ranked: \(ranked.count) candidates (order preserved)")
        }

        // Stage 10: the listener's two dials, applied while the pool is
        // being BUILT. Picking a track and then filtering it out afterwards
        // produces gaps and repeats; choosing correctly does not.
        await applySelectionPolicy(to: ranked)
    }

    // MARK: - Selection policy (stage 10)

    /// Re-reads the policy, applies it to a freshly ranked pool, installs
    /// the result and logs whatever the rule decided.
    private func applySelectionPolicy(to ranked: [SourceCandidate]) async {
        let policy = await selectionPolicy()
        // ONE actor hop per refill, not one await per candidate. The same
        // set then drives the phase counters at the commit point.
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
        // Recorded at the END of every refill, not only in the mid-pool
        // re-filter branch below. Leaving it stale makes the very next
        // nextTrack() see a "changed" policy and re-filter a pool that was
        // just built, double-counting hit_count on every candidate it
        // re-sights — and the audit log then overstates how often the rule
        // actually fired.
        poolPolicy = policy
        logger.info("stage10 policy: \(self.pool.count) candidates (exclusions: \(plan.exclusions.count), shortfall: \(plan.shortfall))")
        await record(plan.exclusions)
    }

    /// Re-applies the policy to the UNPLAYED remainder when a dial has
    /// moved since this pool was built. No-op when it has not.
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
        // Keep the already-played prefix so `cursor` stays valid.
        pool = Array(pool[..<cursor]) + plan.ordered.map(\.candidate)
        poolPolicy = policy
        logger.info("policy changed mid-pool: \(remainder.count) → \(plan.ordered.count) remaining")
        await record(plan.exclusions)
    }

    /// What the mix-set rule gets to see about a candidate. NTS supplies no
    /// duration in practice, so this is a title-arm-only source until the
    /// tracklist API starts populating `duration`.
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
            durationSource: seconds == nil ? nil : "tracklist",
            sourceURL: showURLByCandidate[key]
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

    /// The current pool. `internal`, so invisible outside the module.
    internal func poolSnapshot() -> [SourceCandidate] { pool }

    internal func reapplyPolicyIfChangedForTesting() async {
        await reapplyPolicyIfChanged()
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
