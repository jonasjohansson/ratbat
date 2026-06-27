import Foundation

/// Snapshot of the library-derived layer of a ``TasteProfile``. Kept as
/// a plain `Codable` struct so the whole thing can be dumped to JSON for
/// on-disk caching — computing the profile from scratch on every launch
/// would mean touching every track in the library, which is fine for
/// 5k-ish tracks but wasteful once the cache hits.
public struct TasteProfileSnapshot: Codable, Sendable, Hashable {
    /// Artist → normalized score in `[0, 1]`. 1.0 is whichever artist
    /// has the most tracks in the library; everyone else is linearly
    /// scaled against that maximum.
    public var libraryArtists: [String: Double]
    /// Genre/tag → normalized score in `[0, 1]`. Same normalization as
    /// artists. Keys are lowercased on ingest.
    public var libraryTags: [String: Double]

    public init(libraryArtists: [String: Double] = [:], libraryTags: [String: Double] = [:]) {
        self.libraryArtists = libraryArtists
        self.libraryTags = libraryTags
    }
}

/// Locally-derived taste signals that inform station pool scoring.
///
/// Two layers, blended via ``score(candidateArtist:candidateTags:stationID:history:)``:
/// 1. **Library layer** — passive, derived from Jonas's indexed music. A
///    station candidate whose artist already appears in the library gets a
///    boost; so does a candidate whose tags overlap with the library's
///    dominant genres. Computed from a `[Track]` via ``ingestLibrary(_:)``.
/// 2. **Behavioral layer** (added in Task 3) — active, read from
///    ``HistoryStore``: saves (♥) are boosts, skips (👎) are hard
///    blacklists. Station-scoped so each station learns independently.
///
/// The profile is local-only — no network, no user auth, no Last.fm
/// profile fetching. Everything derives from what Ratbat can see on
/// disk + what the user does inside the app.
public actor TasteProfile {
    private var snapshot: TasteProfileSnapshot = TasteProfileSnapshot()

    public init(snapshot: TasteProfileSnapshot = TasteProfileSnapshot()) {
        self.snapshot = snapshot
    }

    // MARK: - Library ingest

    /// Recompute the library layer from the given tracks. Replaces the
    /// previous snapshot wholesale — the indexer already dedup-merges at
    /// its level, so we trust whatever it hands us is canonical.
    ///
    /// Tracks with empty/whitespace-only artist fields are skipped; those
    /// are usually ambient noise imports or mis-tagged files where the
    /// artist ID3 tag was never set.
    public func ingestLibrary(_ tracks: [Track]) {
        var artistCounts: [String: Int] = [:]
        var tagCounts: [String: Int] = [:]

        for t in tracks {
            let artist = t.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty else { continue }
            artistCounts[artist, default: 0] += 1
            if let raw = t.genre {
                let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !tag.isEmpty {
                    tagCounts[tag, default: 0] += 1
                }
            }
        }

        let maxArtist = max(1, artistCounts.values.max() ?? 1)
        let maxTag = max(1, tagCounts.values.max() ?? 1)
        snapshot = TasteProfileSnapshot(
            libraryArtists: artistCounts.mapValues { Double($0) / Double(maxArtist) },
            libraryTags: tagCounts.mapValues { Double($0) / Double(maxTag) }
        )
    }

    /// Replace the snapshot directly. Used by the on-disk cache loader to
    /// prime a profile without a full library re-scan at startup.
    public func restore(snapshot: TasteProfileSnapshot) {
        self.snapshot = snapshot
    }

    /// The current snapshot. Exposed so a disk-cache writer can capture
    /// the profile without having to walk the library again.
    public func currentSnapshot() -> TasteProfileSnapshot {
        snapshot
    }

    // MARK: - Library-layer accessors

    /// Normalized library score for `artist`, or `0` if the artist isn't
    /// in the library. Exact-match only on a trimmed artist string; fuzzy
    /// matching is deliberately out-of-scope for v1 (see design doc).
    public func libraryArtistScore(for artist: String) -> Double {
        let key = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.libraryArtists[key] ?? 0
    }

    /// Normalized library score for a genre/tag, case-insensitive.
    public func libraryTagScore(for tag: String) -> Double {
        let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return snapshot.libraryTags[key] ?? 0
    }

    /// Boolean membership test — does the library contain this artist at
    /// all? Used by the "exclude my library" station filter and by scoring.
    public func libraryContainsArtist(_ artist: String) -> Bool {
        let key = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.libraryArtists[key] != nil
    }

    // MARK: - Blended scoring (library + per-station behavior)

    #if os(macOS)
    /// Affinity score for a single candidate, blending the library layer
    /// with per-station behavioral signals read from ``HistoryStore``.
    ///
    /// Weighting (sums to 1.0 at max + hard -1 for skip):
    /// ```
    /// score = 0.25 * library_match        // artist in your library
    ///       + 0.20 * tag_match            // tag overlap with library top tags
    ///       + 0.30 * save_affinity        // graduated ♥ for this artist (this station)
    ///       + 0.25 * playthrough_affinity // full listens you didn't skip
    ///       - 1.00 * skip_penalty         // hard blacklist, short-circuits
    /// ```
    /// Callers treat `score < 0` as a filter (drop the candidate) rather
    /// than a sort key — scoring is only meaningful for candidates that
    /// survive the skip blacklist.
    /// `exploration` is the station's Explore↔Comfort dial in `[0, 1]`.
    /// It scales the whole familiarity blend by `comfort = 1 - exploration`:
    /// at 0 the taste ranking is full strength (comfort), at 1 it flattens
    /// to ~0 so unfamiliar candidates rank alongside favourites and the
    /// caller's wildcard/shuffle drives variety (explore). The skip penalty
    /// is never scaled — a 👎 is always a hard veto. Defaults to 0 so
    /// callers that don't pass a dial keep the full-comfort behavior.
    public func score(
        candidateArtist: String,
        candidateTags: [String],
        stationID: UUID,
        history: HistoryStore,
        exploration: Double = 0
    ) async -> Double {
        // Skip blacklist is checked first — no point computing weights
        // for a candidate we're about to drop.
        let skipped: Bool
        do {
            skipped = try await history.hasSkipped(station: stationID, artist: candidateArtist)
        } catch {
            skipped = false     // best-effort: don't propagate DB errors into scoring
        }
        if skipped { return -1.0 }

        let libraryMatch: Double = libraryContainsArtist(candidateArtist) ? 1.0 : 0.0

        let tagMatch: Double
        if candidateTags.isEmpty {
            tagMatch = 0
        } else {
            let overlap = candidateTags
                .map { libraryTagScore(for: $0) }
                .reduce(0, +)
            tagMatch = overlap / Double(candidateTags.count)
        }

        // Save-affinity: how strongly has the user ♥-saved this artist on
        // THIS station? Station-scoped so saves on an ambient station don't
        // swing scoring on a techno station. Graduated rather than binary —
        // ten saves of an artist is a far stronger signal than one, and a
        // save made just now should count more than one from months ago.
        // `savedEntries` is newest-first, so each successive match for the
        // artist gets a smaller harmonic weight (1, 1/2, 1/3, …); the
        // accumulated weight is then squashed through a saturating curve so
        // the term stays in [0, 1) and a single beloved artist can't run
        // away with the pool. One save → ~0.5, two → ~0.65, asymptote 1.0.
        var saveAffinity: Double = 0
        if let saved = try? await history.savedEntries(forStation: stationID, limit: 500) {
            let normalized = candidateArtist
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var weight = 0.0
            var rank = 0
            for entry in saved where entry.artist.lowercased() == normalized {
                rank += 1
                weight += 1.0 / Double(rank)
            }
            saveAffinity = weight > 0 ? 1.0 - pow(0.5, weight) : 0.0
        }

        // Play-through affinity: how many times has the user let a track
        // from this artist run to the end on THIS station? A full listen is
        // a quieter signal than a deliberate ♥, but it accumulates — an
        // artist the user never skips earns its place. Same saturating
        // shape as save-affinity. 1 play → 0.5, 2 → 0.75, asymptote 1.0.
        var playThroughAffinity: Double = 0
        if let plays = try? await history.playThroughCount(forStation: stationID, artist: candidateArtist),
           plays > 0 {
            playThroughAffinity = 1.0 - pow(0.5, Double(plays))
        }

        let comfort = 1.0 - min(max(exploration, 0), 1)
        return comfort * (0.25 * libraryMatch
                        + 0.20 * tagMatch
                        + 0.30 * saveAffinity
                        + 0.25 * playThroughAffinity)
    }
    #endif
}
