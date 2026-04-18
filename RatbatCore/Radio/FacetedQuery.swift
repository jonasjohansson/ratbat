import Foundation

/// Faceted query over candidate tracks. Consumed by both
/// ``LastFMStationConfig`` and ``BandcampStationConfig``; the per-source
/// controllers translate each facet into the appropriate filter stage.
///
/// Facet semantics:
/// - `genreTags`: OR within the array (subject to ``tagMatch``); required (>= 1).
/// - `yearMin` / `yearMax`: closed year range, AND against other facets.
/// - `regions`: OR within the array, AND across facets. ISO 3166 alpha-2 codes ("JP", "DE").
/// - `tagMatch`: any | all. Applies to `genreTags` only — era and region
///   are always AND'd regardless.
public struct FacetedQuery: Hashable, Sendable, Codable {
    public var genreTags: [String]
    public var yearMin: Int?
    public var yearMax: Int?
    public var regions: [String]
    public var tagMatch: TagMatch
    public var popularity: PopularityTier
    public var excludeOwnedLibrary: Bool
    public var excludedArtists: Set<String>

    public init(
        genreTags: [String],
        yearMin: Int? = nil,
        yearMax: Int? = nil,
        regions: [String] = [],
        tagMatch: TagMatch = .any,
        popularity: PopularityTier = .middle,
        excludeOwnedLibrary: Bool = false,
        excludedArtists: Set<String> = []
    ) {
        self.genreTags = genreTags
        self.yearMin = yearMin
        self.yearMax = yearMax
        self.regions = regions
        self.tagMatch = tagMatch
        self.popularity = popularity
        self.excludeOwnedLibrary = excludeOwnedLibrary
        self.excludedArtists = excludedArtists
    }
}

/// Intra-facet combination strategy for `genreTags`.
public enum TagMatch: String, Hashable, Codable, Sendable {
    case any  // OR — default; broadest pool
    case all  // AND — narrower, used to intersect tags like "techno" + "ambient"
}

/// Popularity-tier partitioning. Last.fm-only signal; ignored by the
/// Bandcamp controller (Bandcamp has no listener count).
public enum PopularityTier: String, Hashable, Codable, Sendable {
    case hits       // top 10% by listener count
    case middle     // 10-50th percentile — default, balanced
    case deepCuts   // bottom 50% — underground / discovery
}

// Pin the on-disk schema explicitly. `.ratbat-stations.json` lives on
// a shared Google Drive and is read by multiple machines, so we don't
// want Swift's synthesized Codable keys tracking property identifiers
// — a future rename would silently break compatibility otherwise.
// The synthesized `init(from:)` / `encode(to:)` still apply; we just
// nail down the key names here.
extension FacetedQuery {
    private enum CodingKeys: String, CodingKey {
        case genreTags, yearMin, yearMax, regions
        case tagMatch, popularity
        case excludeOwnedLibrary, excludedArtists
    }
}
