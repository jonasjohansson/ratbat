import Foundation

/// Tag-combination strategy for a Last.fm-backed station.
///
/// `any` (the default) unions the top-tracks results across every
/// configured tag — broadest pool, matches the v1 shape.
/// `all` intersects by (artist, title) across tags — narrower and more
/// specific, useful for combining a genre tag with a decade tag.
public enum LastFMTagMode: String, Hashable, Codable, Sendable {
    case any
    case all
}

/// Popularity-tier partitioning applied after tag fetch. Splits the raw
/// candidates by ``LastFMClient/TrackCandidate/listeners`` and keeps the
/// requested tier.
///
/// - `hits`: top 10% (most-listened) — comfort / mainstream
/// - `middle`: 10-50th percentile — default, balanced
/// - `deepCuts`: bottom 50% — underground / discovery
public enum LastFMPopularityTier: String, Hashable, Codable, Sendable {
    case hits
    case middle
    case deepCuts
}

/// How hard the station should work to verify that a candidate is
/// actually in the requested genre. Last.fm tags are user-contributed
/// and noisy — one wrongly-tagged track can drag a whole artist into
/// the wrong genre pool (famously, "Groove Coverage — Poison" under
/// "techno"). Verifying that the artist's *own* top tags include the
/// query tag filters most of that noise out at one extra API call per
/// unique artist.
public enum LastFMPrecisionMode: String, Hashable, Codable, Sendable {
    case off        // trust raw tag.getTopTracks hits — fast, noisy
    case verified   // artist's top-5 tags must include the query tag (default)
    case strict     // artist's top-3 tags must include the query tag
}

/// Blueprint for a generative Last.fm-backed station.
///
/// Mirrors ``NTSStationConfig`` in shape so the two station kinds read
/// identically at the top of the station-store JSON. Filter fields were
/// added in the taste-intelligence work — older stations on disk that
/// predate these fields decode with the documented defaults (custom
/// `init(from:)` handles the absence).
public struct LastFMStationConfig: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var tags: [String]
    public var yearMin: Int?
    public var yearMax: Int?
    public var shufflePool: Bool

    // Filter suite — added alongside the taste-intelligence work.
    public var tagMode: LastFMTagMode
    public var popularity: LastFMPopularityTier
    public var precision: LastFMPrecisionMode
    public var excludeOwnedLibrary: Bool
    public var excludedArtists: Set<String>

    public init(
        id: UUID = UUID(),
        name: String,
        tags: [String],
        yearMin: Int? = nil,
        yearMax: Int? = nil,
        shufflePool: Bool = true,
        tagMode: LastFMTagMode = .any,
        popularity: LastFMPopularityTier = .middle,
        precision: LastFMPrecisionMode = .verified,
        excludeOwnedLibrary: Bool = false,
        excludedArtists: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.yearMin = yearMin
        self.yearMax = yearMax
        self.shufflePool = shufflePool
        self.tagMode = tagMode
        self.popularity = popularity
        self.precision = precision
        self.excludeOwnedLibrary = excludeOwnedLibrary
        self.excludedArtists = excludedArtists
    }

    // MARK: - Codable with backwards compatibility

    // Hand-rolled Codable so older on-disk configs (missing the filter
    // fields entirely) decode cleanly with documented defaults instead
    // of throwing. Swift's auto-synthesised Codable on a struct with
    // stored-property defaults would still fail on a missing key, so we
    // use `decodeIfPresent` for every field added after v1.
    private enum CodingKeys: String, CodingKey {
        case id, name, tags, yearMin, yearMax, shufflePool
        case tagMode, popularity, precision, excludeOwnedLibrary, excludedArtists
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.tags = try c.decode([String].self, forKey: .tags)
        self.yearMin = try c.decodeIfPresent(Int.self, forKey: .yearMin)
        self.yearMax = try c.decodeIfPresent(Int.self, forKey: .yearMax)
        self.shufflePool = try c.decodeIfPresent(Bool.self, forKey: .shufflePool) ?? true
        self.tagMode = try c.decodeIfPresent(LastFMTagMode.self, forKey: .tagMode) ?? .any
        self.popularity = try c.decodeIfPresent(LastFMPopularityTier.self, forKey: .popularity) ?? .middle
        self.precision = try c.decodeIfPresent(LastFMPrecisionMode.self, forKey: .precision) ?? .verified
        self.excludeOwnedLibrary = try c.decodeIfPresent(Bool.self, forKey: .excludeOwnedLibrary) ?? false
        self.excludedArtists = try c.decodeIfPresent(Set<String>.self, forKey: .excludedArtists) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(yearMin, forKey: .yearMin)
        try c.encodeIfPresent(yearMax, forKey: .yearMax)
        try c.encode(shufflePool, forKey: .shufflePool)
        try c.encode(tagMode, forKey: .tagMode)
        try c.encode(popularity, forKey: .popularity)
        try c.encode(precision, forKey: .precision)
        try c.encode(excludeOwnedLibrary, forKey: .excludeOwnedLibrary)
        try c.encode(excludedArtists, forKey: .excludedArtists)
    }
}
