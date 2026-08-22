#if os(macOS)
import Foundation
import OSLog

/// Orchestrator for a Library Radio station: turns a
/// ``LibraryRadioStationConfig`` into a taste-ordered walk of the owner's
/// own indexed library (signal-model design §4, owned-tracks-only v1).
///
/// Deliberately much smaller than ``LastFMStationController``, because
/// most of that controller is machinery this kind does not need:
/// - **No client, no resolver, no MusicBrainz.** Every candidate is a
///   ``Track`` the ``LibraryIndexer`` already parsed off disk — the file
///   IS the resolution, so there are no retry budgets, no transient
///   failures, and no per-candidate network calls.
/// - **No per-station history dedup.** A generative station never plays
///   the same track twice; a library station is the owner's own records
///   and must loop forever like ``PlaylistSource`` does — running "dry"
///   because every file has played once would be a bug, not a feature.
///   Instead, each *lap* plays every pooled track exactly once, and the
///   next refill re-derives the pool from the live library and the live
///   taste signals, which is what makes the station drift as the
///   library and the owner's boosts/saves/skips drift.
/// - **No exploration dial.** The wire contract answers `wrongKind` for
///   it on this kind; scoring runs at full comfort and `shufflePool`
///   supplies the variety.
///
/// What it KEEPS from the generative pipeline, so the kinds feel like
/// siblings on the inside too:
/// - facet filtering (tags / era / excluded artists — see
///   ``LibraryRadioStationConfig`` for exactly which facets a local
///   file can honor and why regions/popularity are ignored),
/// - ``TasteProfile`` scoring with the skip blacklist as a hard drop,
/// - the shared ``SelectionPlanner`` stage (mix-set filter + the
///   new-vs-owned dial) with audit rows stamped `sourceKind:
///   "libraryRadio"`. The dial legitimately produces a shortfall row
///   here whenever it asks for new music — every candidate is owned by
///   definition — and recording that is the honest answer to "why does
///   my 100% dial do nothing on Library Radio".
public actor LibraryRadioStationController {

    public enum Error: Swift.Error, Sendable {
        /// The facet filter matched nothing in the library — the station
        /// has no possible pool and genuinely ends (the analogue of
        /// ``LastFMStationController/Error/noTracksForTags(_:)``).
        case emptyPool
    }

    private let config: LibraryRadioStationConfig
    /// Live read of the indexed library, one hop per refill. A provider
    /// rather than a `[Track]` value so a rescan (new downloads, a
    /// Drive sync) reaches the next refill without a restart — the
    /// self-seeding promise is "drifts as the library drifts".
    private let libraryTracks: @Sendable () async -> [Track]
    /// Optional so a broadcaster booted without a history store (tests,
    /// minimal init) still broadcasts: without it the behavioral half of
    /// scoring (saves / play-throughs / skips) is unavailable and the
    /// library layer alone ranks the pool.
    private let history: HistoryStore?
    private let tasteProfile: TasteProfile
    /// Live read of the listener's two dials, re-read at every refill —
    /// same idiom, same reason as ``LastFMStationController``.
    private let selectionPolicy: @Sendable () async -> SelectionPolicy
    /// Audit sink for the planner's exclusion rows. A closure (the
    /// ``PlaylistSource`` shape) rather than a store handle so the actor
    /// stays constructible without a database in tests.
    private let recordExclusions: (@Sendable ([SelectionExclusionRecord]) async -> Void)?

    private let logger = Logger(subsystem: RatbatLog.subsystem, category: "library-radio-station")

    /// `source_kind` stamped on this station's exclusion rows, and the
    /// spelling `/exclusions` clients see.
    private static let sourceKind = "libraryRadio"

    private var pool: [Track] = []
    private var cursor: Int = 0
    /// The policy the current pool was built under, so a moved dial can
    /// re-plan the unplayed remainder instead of waiting out the lap —
    /// a lap through a whole library can be days long, which is too
    /// late for a mix-set toggle to feel connected to anything.
    private var poolPolicy: SelectionPolicy?
    /// Owned-artist keys captured at the last refill; here they are the
    /// *entire* candidate set's artists (everything is owned), kept so
    /// the planner's phase counters use the same key rule as everywhere
    /// else rather than a special case.
    private var ownedArtistKeys: Set<String> = []
    private var playedNew = 0
    private var playedTotal = 0

    public init(
        config: LibraryRadioStationConfig,
        libraryTracks: @escaping @Sendable () async -> [Track],
        history: HistoryStore? = nil,
        tasteProfile: TasteProfile,
        selectionPolicy: @escaping @Sendable () async -> SelectionPolicy = { .default },
        recordExclusions: (@Sendable ([SelectionExclusionRecord]) async -> Void)? = nil
    ) {
        self.config = config
        self.libraryTracks = libraryTracks
        self.history = history
        self.tasteProfile = tasteProfile
        self.selectionPolicy = selectionPolicy
        self.recordExclusions = recordExclusions
    }

    // MARK: - Public

    /// The next owned track to play. Throws ``Error/emptyPool`` only
    /// when the filtered library is genuinely empty; otherwise the
    /// station loops forever, refilling (and re-deriving taste order)
    /// at the end of each lap.
    ///
    /// Boost steering note: there is deliberately no `requestReseed()`
    /// here. Boosting an owned track records artist affinity in the
    /// history store, and this controller re-reads those signals at
    /// every refill — the pool has no seed graph to re-aim, so the
    /// ``TrackSource/noteSteeringChanged()`` default no-op is the whole
    /// design, not a missing feature.
    public func nextTrack() async throws -> Track {
        await reapplyPolicyIfChanged()
        if cursor >= pool.count {
            try await refillPool()
        }
        // refillPool either threw or left a non-empty pool.
        let track = pool[cursor]
        cursor += 1
        playedTotal += 1
        if !ownedArtistKeys.contains(SelectionOrdering.artistKey(track.artist)) {
            playedNew += 1
        }
        return track
    }

    // MARK: - Facet filter

    /// A local file's answer to "what are your tags": the genre field,
    /// split on the separators multi-genre taggers actually use, so
    /// "Ambient; Downtempo" matches both an `ambient` and a `downtempo`
    /// query tag — and so `tagMatch: .all` has a fighting chance on
    /// files that carry more than one genre.
    nonisolated static func tagSet(of track: Track) -> Set<String> {
        guard let raw = track.genre else { return [] }
        return Set(
            raw.split(whereSeparator: { ",;/".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    /// The facet filter, pure and `nonisolated` so tests exercise every
    /// branch without an actor hop. Which facets apply — and which are
    /// deliberately ignored — is documented on
    /// ``LibraryRadioStationConfig``; this function is that contract's
    /// implementation.
    nonisolated static func matches(_ track: Track, query: FacetedQuery) -> Bool {
        // Tags: empty query = whole library. Otherwise the track's tag
        // set must intersect (`.any`) or cover (`.all`) the query tags.
        // A track with no genre tag cannot prove membership, so it is
        // excluded while a tag filter is active.
        if !query.genreTags.isEmpty {
            let queryTags = Set(query.genreTags.map { $0.lowercased() })
            let trackTags = tagSet(of: track)
            switch query.tagMatch {
            case .any:
                guard !trackTags.isDisjoint(with: queryTags) else { return false }
            case .all:
                guard queryTags.isSubset(of: trackTags) else { return false }
            }
        }
        // Era: honored where the file carries a year tag. A track with
        // no year is excluded while a bound is set — including unknowns
        // would water down the era the owner asked for, and "honored
        // where metadata allows" means the filter keeps meaning
        // something, not that it silently admits the unfilterable.
        if query.yearMin != nil || query.yearMax != nil {
            guard let year = track.year else { return false }
            if let lo = query.yearMin, year < lo { return false }
            if let hi = query.yearMax, year > hi { return false }
        }
        // Excluded artists: honored, case-insensitively.
        if query.excludedArtists.contains(where: {
            $0.caseInsensitiveCompare(track.artist) == .orderedSame
        }) {
            return false
        }
        // `regions`, `popularity`, `excludeOwnedLibrary`: deliberately
        // not consulted — no file metadata / no listener counts / all
        // candidates owned. See LibraryRadioStationConfig.
        return true
    }

    // MARK: - Pool pipeline

    /// Rebuild the pool: read the live library, filter by the facets,
    /// score by taste (skip blacklist drops), softly shuffle, then run
    /// the shared ``SelectionPlanner`` stage. Internal (not private) so
    /// tests can drive refills directly — the
    /// ``LastFMStationController`` precedent.
    internal func refillPool() async throws {
        let tracks = await libraryTracks()
        let candidates = tracks.filter { Self.matches($0, query: config.query) }
        logger.info("filter: \(candidates.count)/\(tracks.count) library tracks match")
        guard !candidates.isEmpty else {
            pool = []
            cursor = 0
            poolPolicy = nil
            throw Error.emptyPool
        }

        // Taste scoring. Skips are a hard veto (score < 0); everything
        // else ranks high→low. Without a history store only the library
        // layer is available, so score the candidate against it directly
        // — same two terms `TasteProfile.score` would blend, minus the
        // behavioral half it cannot answer.
        var scored: [(track: Track, score: Double)] = []
        for track in candidates {
            let tags = Array(Self.tagSet(of: track))
            let s: Double
            if let history {
                s = await tasteProfile.score(
                    candidateArtist: track.artist,
                    candidateTags: tags,
                    stationID: config.id,
                    history: history
                )
            } else {
                let artistScore = await tasteProfile.libraryArtistScore(for: track.artist)
                var tagScore = 0.0
                for tag in tags {
                    tagScore += await tasteProfile.libraryTagScore(for: tag)
                }
                s = 0.5 * artistScore
                    + 0.5 * (tags.isEmpty ? 0 : tagScore / Double(tags.count))
            }
            if s < 0 { continue }     // 👎 blacklist hit
            scored.append((track, s))
        }
        scored.sort { $0.score > $1.score }
        logger.info("scored: \(scored.count) candidates ranked")
        guard !scored.isEmpty else {
            // Everything the filter admitted is skip-blacklisted. Same
            // "genuinely over" answer as an empty filter result.
            pool = []
            cursor = 0
            poolPolicy = nil
            throw Error.emptyPool
        }

        var ranked = scored.map(\.track)
        if config.shufflePool {
            // Same mild 4-track-window jitter the generative kinds use,
            // so a lap leads with *a* favourite rather than always THE
            // favourite. Whole-pool shuffling would throw the taste
            // ranking away, which is the one thing this kind is for.
            ranked = Self.softShuffle(ranked, window: 4)
        }

        await applySelectionPolicy(to: ranked)
    }

    /// Stage: the listener's two global dials, applied while the pool is
    /// built — never after a track is chosen (the planner's own rule).
    private func applySelectionPolicy(to ranked: [Track]) async {
        let policy = await selectionPolicy()
        ownedArtistKeys = await tasteProfile.ownedArtistKeys()

        let plan = SelectionPlanner.plan(
            ranked.map { SelectionInput(candidate: $0, subject: Self.selectionSubject(for: $0)) },
            policy: policy,
            phase: (new: playedNew, total: playedTotal),
            sourceKind: Self.sourceKind,
            ownedArtistKeys: ownedArtistKeys,
            subject: { $0.subject }
        )
        pool = plan.ordered.map(\.candidate)
        cursor = 0
        poolPolicy = policy
        logger.info("policy: \(self.pool.count) candidates (exclusions: \(plan.exclusions.count), shortfall: \(plan.shortfall))")
        if let recordExclusions, !plan.exclusions.isEmpty {
            await recordExclusions(plan.exclusions)
        }
    }

    /// Re-plan the unplayed remainder when a dial moved since this pool
    /// was built; no-op otherwise. Mirrors ``LastFMStationController``.
    private func reapplyPolicyIfChanged() async {
        guard let built = poolPolicy, cursor < pool.count else { return }
        let policy = await selectionPolicy()
        guard built != policy else { return }

        let remainder = Array(pool[cursor...])
        let plan = SelectionPlanner.plan(
            remainder.map { SelectionInput(candidate: $0, subject: Self.selectionSubject(for: $0)) },
            policy: policy,
            phase: (new: playedNew, total: playedTotal),
            sourceKind: Self.sourceKind,
            ownedArtistKeys: ownedArtistKeys,
            subject: { $0.subject }
        )
        pool = Array(pool[..<cursor]) + plan.ordered.map(\.candidate)
        poolPolicy = policy
        logger.info("policy changed mid-pool: \(remainder.count) → \(plan.ordered.count) remaining")
        if let recordExclusions, !plan.exclusions.isEmpty {
            await recordExclusions(plan.exclusions)
        }
    }

    /// What the mix-set rule sees. Unlike Last.fm this source has the
    /// EXACT file duration (the indexer measured it), so the duration
    /// arm classifies precisely the thing it would remove — the
    /// ``PlaylistSource`` property, inherited on purpose.
    nonisolated private static func selectionSubject(for track: Track) -> SelectionSubject {
        SelectionSubject(
            artist: track.artist.isEmpty ? "Unknown" : track.artist,
            title: track.title.isEmpty ? track.url.lastPathComponent : track.title,
            durationSeconds: track.duration > 0 ? track.duration : nil,
            durationSource: track.duration > 0 ? "library" : nil,
            sourceURL: track.url
        )
    }

    /// Shuffle within fixed-size windows — the same jitter
    /// ``LastFMStationController`` applies, reimplemented here because
    /// that copy is private to its actor.
    nonisolated private static func softShuffle<T>(_ items: [T], window: Int) -> [T] {
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

    // MARK: - Test seams

    internal func poolSnapshot() -> [Track] { pool }
}
#endif
