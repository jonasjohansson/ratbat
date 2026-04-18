import Foundation

/// Blueprint for a generative NTS-backed station. Facet shape delegated
/// to ``FacetedQuery`` — mirrors ``LastFMStationConfig`` /
/// ``BandcampStationConfig`` so the three generative sources share the
/// same vocabulary (genre tags, era, region, tag-match, popularity,
/// library exclusion, excluded artists).
///
/// `id` is the station identity used by ``HistoryStore`` for dedup, so
/// it remains stable across launches — persist the whole config via
/// `Codable` rather than regenerating the UUID.
///
/// Migration: the pre-faceted on-disk shape used top-level `tags` +
/// `yearMin/yearMax` fields. The custom `init(from:)` below detects
/// that shape and hydrates a ``FacetedQuery`` on the fly — no
/// ``StationStore`` version bump required.
public struct NTSStationConfig: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var query: FacetedQuery
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

    // MARK: - Codable with legacy-shape migration

    private enum CodingKeys: String, CodingKey {
        // New shape
        case id, name, query, shufflePool
        // Legacy keys (decode-only, never written)
        case tags, yearMin, yearMax
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.shufflePool = try c.decodeIfPresent(Bool.self, forKey: .shufflePool) ?? true

        if let q = try c.decodeIfPresent(FacetedQuery.self, forKey: .query) {
            self.query = q
        } else {
            // Legacy shape — hydrate a FacetedQuery from the flat fields.
            // NTS's legacy shape was simpler than Last.fm's (no tagMode /
            // popularity / excludeOwnedLibrary / excludedArtists), so we
            // only migrate the three fields it actually carried.
            let tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            let yearMin = try c.decodeIfPresent(Int.self, forKey: .yearMin)
            let yearMax = try c.decodeIfPresent(Int.self, forKey: .yearMax)
            self.query = FacetedQuery(
                genreTags: tags,
                yearMin: yearMin,
                yearMax: yearMax
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(query, forKey: .query)
        try c.encode(shufflePool, forKey: .shufflePool)
    }
}
