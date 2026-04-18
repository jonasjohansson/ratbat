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

// MARK: - Suggested name

extension FacetedQuery {
    /// Synthesize a human-readable station name from the facets. Used
    /// when the user creates a station without typing a name, and shown
    /// live as the Add-sheet placeholder so the behaviour is discoverable.
    ///
    /// Shape examples:
    /// - `Techno`
    /// - `Techno · House`
    /// - `Techno · House · Ambient · +1 more`
    /// - `Techno (1990s)`
    /// - `Techno (1990–2005)`
    /// - `Japanese Techno`
    /// - `Techno (JP · DE)`
    /// - `Japanese Techno (1990s)`
    /// - `New Station` (empty facets)
    public var suggestedName: String {
        guard !genreTags.isEmpty else { return "New Station" }

        // Genre tags — pretty-print, join with middle-dot, truncate beyond 3.
        let prettyTags = genreTags.map(Self.prettyTag)
        let tagPart: String
        let shown = Array(prettyTags.prefix(3))
        if prettyTags.count <= 3 {
            tagPart = shown.joined(separator: " · ")
        } else {
            let extra = prettyTags.count - shown.count
            tagPart = shown.joined(separator: " · ") + " · +\(extra) more"
        }

        // Region adjective prefix for a single known country; else the
        // multi-region parenthetical code list is appended after the era.
        let singleRegionAdjective: String? = {
            guard regions.count == 1, let code = regions.first else { return nil }
            return Self.regionAdjective(forCode: code)
        }()

        var head: String
        if let adj = singleRegionAdjective {
            head = "\(adj) \(tagPart)"
        } else {
            head = tagPart
        }

        // Suffix segments — era and multi/fallback-region parentheticals.
        var suffixes: [String] = []
        if let era = Self.eraSuffix(yearMin: yearMin, yearMax: yearMax) {
            suffixes.append(era)
        }
        if regions.count > 1 {
            suffixes.append("(\(regions.joined(separator: " · ")))")
        } else if regions.count == 1, singleRegionAdjective == nil,
                  let code = regions.first {
            // Unknown country code — fall back to parenthetical form so we
            // don't leave the region silently off the generated name.
            suffixes.append("(\(code))")
        }

        var result = head
        for s in suffixes {
            result += " " + s
        }

        // Cap overall length at 60 chars with an ellipsis.
        let maxLen = 60
        if result.count > maxLen {
            let cutoff = result.index(result.startIndex, offsetBy: maxLen - 1)
            result = String(result[..<cutoff]) + "…"
        }
        return result
    }

    /// Title-case a tag, preserving short all-lower acronyms (`idm` → `IDM`).
    private static func prettyTag(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        // If the whole tag is a single short token that's all letters and
        // ≤ 3 chars, treat it as an acronym.
        if !trimmed.contains(" "),
           trimmed.count <= 3,
           trimmed.allSatisfy({ $0.isLetter }) {
            return trimmed.uppercased()
        }
        // Otherwise, capitalize the first letter of each word and leave
        // subsequent characters alone (handles "hip hop", "dungeon synth").
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        let titled = words.map { (w: Substring) -> String in
            guard let first = w.first else { return String(w) }
            return String(first).uppercased() + w.dropFirst()
        }
        return titled.joined(separator: " ")
    }

    /// Render the year range as a parenthetical era string, or `nil`
    /// when both bounds are missing.
    private static func eraSuffix(yearMin: Int?, yearMax: Int?) -> String? {
        switch (yearMin, yearMax) {
        case (nil, nil):
            return nil
        case let (y?, nil):
            return "(from \(y))"
        case let (nil, y?):
            return "(through \(y))"
        case let (lo?, hi?):
            if lo == hi { return "(\(lo))" }
            // Decade-aligned ranges render as "1990s" or "1990s–2000s".
            let loDecade = (lo / 10) * 10
            let hiDecade = (hi / 10) * 10
            let loAligned = lo == loDecade
            let hiAligned = hi == loDecade + 9
            if loAligned && hiAligned {
                return "(\(loDecade)s)"
            }
            // Multi-decade but still aligned to decade boundaries.
            let hiAlignedEnd = hi == hiDecade + 9
            if loAligned && hiAlignedEnd && hiDecade > loDecade {
                return "(\(loDecade)s–\(hiDecade)s)"
            }
            // Mixed — use an en-dash between raw years.
            return "(\(lo)–\(hi))"
        }
    }

    /// Map known ISO 3166 alpha-2 codes to an English adjective. Returns
    /// `nil` for codes we haven't curated — callers fall back to a
    /// parenthetical form so the region still shows up in the name.
    private static func regionAdjective(forCode code: String) -> String? {
        switch code.uppercased() {
        case "JP": return "Japanese"
        case "DE": return "German"
        case "FR": return "French"
        case "SE": return "Swedish"
        case "GB", "UK": return "British"
        case "US": return "American"
        case "IT": return "Italian"
        case "BR": return "Brazilian"
        default: return nil
        }
    }
}
