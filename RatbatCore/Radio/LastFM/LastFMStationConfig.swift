import Foundation

/// Blueprint for a generative Last.fm-backed station. The facet shape is
/// delegated entirely to ``FacetedQuery``; this struct just holds the
/// identity + one Last.fm-specific lifecycle flag.
///
/// Migration: older on-disk configs predating the faceted redesign
/// encoded facet fields at the top level (`tags`, `yearMin`, `yearMax`,
/// `tagMode`, `popularity`, `excludeOwnedLibrary`, `excludedArtists`).
/// The custom `init(from:)` below detects those and hydrates a
/// ``FacetedQuery`` on the fly — no ``StationStore`` version bump needed.
public struct LastFMStationConfig: Identifiable, Hashable, Sendable, Codable {
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
        case tags
        case yearMin, yearMax
        case tagMode, popularity, excludeOwnedLibrary, excludedArtists
        // `precision` was also a legacy field — dropped entirely, handled
        // implicitly inside LastFMStationController now.
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
            let tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            let legacyYearMin = try c.decodeIfPresent(Int.self, forKey: .yearMin)
            let legacyYearMax = try c.decodeIfPresent(Int.self, forKey: .yearMax)
            let tagMode = try c.decodeIfPresent(String.self, forKey: .tagMode) ?? "any"
            let popularity = try c.decodeIfPresent(String.self, forKey: .popularity) ?? "middle"
            let excludeOwnedLibrary = try c.decodeIfPresent(Bool.self, forKey: .excludeOwnedLibrary) ?? false
            let excludedArtists = try c.decodeIfPresent(Set<String>.self, forKey: .excludedArtists) ?? []

            // Migrate decade tags (e.g. "1990s") out of the flat `tags` list
            // and into numeric yearMin/yearMax bounds. They're temporal,
            // not genre — carrying them through as string tags was the
            // root cause of the Exaltasamba bug (temporal info
            // masquerading as genre proof in stage-5 precision).
            //
            // When multiple decades are present we union them: `1970s` +
            // `1980s` becomes yearMin 1970, yearMax 1989. Any existing
            // yearMin/yearMax from the legacy encoding is folded in the
            // same way so we never narrow the user's intent.
            var liftedMin: Int? = legacyYearMin
            var liftedMax: Int? = legacyYearMax
            var cleanedTags: [String] = []
            for tag in tags {
                if let (decadeLo, decadeHi) = Self.decadeBounds(for: tag) {
                    liftedMin = min(liftedMin ?? decadeLo, decadeLo)
                    liftedMax = max(liftedMax ?? decadeHi, decadeHi)
                } else {
                    cleanedTags.append(tag)
                }
            }

            self.query = FacetedQuery(
                genreTags: cleanedTags,
                yearMin: liftedMin,
                yearMax: liftedMax,
                regions: [],
                tagMatch: TagMatch(rawValue: tagMode) ?? .any,
                popularity: PopularityTier(rawValue: popularity) ?? .middle,
                excludeOwnedLibrary: excludeOwnedLibrary,
                excludedArtists: excludedArtists
            )
        }
    }

    /// Parse a decade-style tag ("1990s", "2000s", …) into inclusive
    /// numeric bounds. Returns nil for any other shape so genre tags
    /// that merely start with four digits are left alone.
    private static func decadeBounds(for tag: String) -> (Int, Int)? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 5,
              trimmed.hasSuffix("s"),
              let decade = Int(trimmed.dropLast()),
              decade >= 1000, decade <= 9990,
              decade % 10 == 0 else {
            return nil
        }
        return (decade, decade + 9)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(query, forKey: .query)
        try c.encode(shufflePool, forKey: .shufflePool)
    }
}
