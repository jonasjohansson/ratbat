import Foundation

/// Blueprint for a Library Radio station — the self-seeding kind that
/// plays ONLY tracks the owner already has on disk, chosen by the taste
/// profile instead of a hand-picked queue (signal-model design §4, as
/// revised for v1: the pool is the indexed library itself, not a
/// Last.fm expansion, so no API key and no resolver are ever needed).
///
/// The facet shape is delegated to the shared ``FacetedQuery`` so the
/// desktop editor and the web `/stations/*` wire reuse one vocabulary,
/// but a local library can only honor the facets its file tags can
/// answer. Semantics, stated once so every consumer agrees:
/// - `genreTags` filter against each file's genre tag. An EMPTY list is
///   legal here (unlike the generative kinds) and means "the whole
///   library" — that is the station's whole point.
/// - `yearMin`/`yearMax` are honored where the file carries a year tag;
///   a track with no year is excluded while an era bound is set, because
///   including unknowns would pollute the era the owner asked for.
/// - `regions` are IGNORED: file metadata has no artist-country field,
///   and pretending to filter on data that doesn't exist would be a
///   silent lie. The desktop sheet and web copy say so.
/// - `popularity` is IGNORED: it is a Last.fm listener-count signal and
///   a local file has no listener count.
/// - `excludeOwnedLibrary` is meaningless — every candidate is owned by
///   definition — so ``StationManager`` normalizes it to `false` on
///   every create/update rather than persisting a contradiction.
/// - `excludedArtists` are honored (case-insensitive).
///
/// There is deliberately NO `exploration` dial and NO `sort`: the wire
/// contract answers `wrongKind` for both, and the pool ordering is the
/// taste score with the shared ``SelectionPolicy`` stage applied.
public struct LibraryRadioStationConfig: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var query: FacetedQuery
    /// Soft-shuffles the taste-ranked pool in small windows so a lap
    /// through the library doesn't open with the same top-scored track
    /// every time. Same knob, same meaning as the generative kinds.
    public var shufflePool: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        query: FacetedQuery,
        shufflePool: Bool = true
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.shufflePool = shufflePool
    }
}

// Pin the on-disk schema explicitly — `.ratbat-stations.json` is shared
// across machines via Drive, so key names must not track Swift property
// renames (the FacetedQuery.swift rationale, applied to every config).
extension LibraryRadioStationConfig {
    private enum CodingKeys: String, CodingKey {
        case id, name, query, shufflePool
    }
}
