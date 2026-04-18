#if os(macOS)
import Foundation
import OSLog

/// Common candidate shape across Last.fm and Bandcamp sources. Enables
/// shared post-filter stages in ``FacetedPipeline``.
///
/// The `resolvedURL` field is the key piece of architecture: sources that
/// already know the audio URL (Bandcamp) carry it through, letting
/// ``TrackResolver`` skip YouTube-Music matching.
public struct SourceCandidate: Sendable, Hashable {
    public let artist: String
    public let title: String
    public let resolvedURL: URL?
    public let listenersHint: Int?
    public let matchedTags: Set<String>

    public init(
        artist: String,
        title: String,
        resolvedURL: URL? = nil,
        listenersHint: Int? = nil,
        matchedTags: Set<String> = []
    ) {
        self.artist = artist
        self.title = title
        self.resolvedURL = resolvedURL
        self.listenersHint = listenersHint
        self.matchedTags = matchedTags
    }
}

/// Shared post-filter stages used by both ``LastFMStationController`` and
/// ``BandcampStationController``. Stateless namespace — all state is
/// carried through parameters.
public enum FacetedPipeline {
    static let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "faceted-pipeline")

    // MARK: - Tag mode (stage 2)

    /// Applies `.any` (union) / `.all` (intersection) across the candidate
    /// tags vs the required query tags.
    ///
    /// Precondition for `.any`: the caller (stage 1 seed fetch) has already
    /// ensured every candidate matched at least one of the `required` tags.
    /// The function does not defensively re-check this — passing in candidates
    /// with empty matchedTags will let them through unfiltered.
    public static func applyTagMode(
        _ candidates: [(SourceCandidate, Set<String>)],
        required: Set<String>,
        mode: TagMatch
    ) -> [SourceCandidate] {
        switch mode {
        case .any:
            return candidates.map(\.0)
        case .all:
            let lowered = Set(required.map { $0.lowercased() })
            return candidates.compactMap { (cand, tags) in
                let loweredTags = Set(tags.map { $0.lowercased() })
                return loweredTags.isSuperset(of: lowered) ? cand : nil
            }
        }
    }

    // MARK: - Exclusions (stage 5)

    public static func applyExclusions(
        _ candidates: [SourceCandidate],
        excludedArtists: Set<String>,
        excludeOwnedLibrary: Bool,
        tasteProfile: TasteProfile?
    ) async -> [SourceCandidate] {
        let excludedLower = Set(excludedArtists.map { $0.lowercased() })
        var kept: [SourceCandidate] = []
        for c in candidates {
            if excludedLower.contains(c.artist.lowercased()) { continue }
            if excludeOwnedLibrary, let tp = tasteProfile {
                let owned = await tp.libraryContainsArtist(c.artist)
                if owned { continue }
            }
            kept.append(c)
        }
        return kept
    }
}

/// Minimal surface the pipeline needs from a MusicBrainz-style lookup.
/// Lets tests substitute a stub. The real ``MusicBrainzClient`` conforms
/// via an extension in the client file.
public protocol MusicBrainzLookup: Actor {
    func firstReleaseYear(artist: String, title: String) async -> Int?
    func countryCode(forArtist artist: String) async -> String?
}

extension FacetedPipeline {
    // MARK: - Era filter (stage 6)

    /// Drops candidates whose MB-reported release year falls outside the
    /// configured range. Candidates with unknown year (MB said nothing)
    /// are **kept** — fail-open per the design doc, since MB coverage on
    /// Bandcamp bedroom-producer material is ~50%.
    public static func applyEraFilter(
        _ candidates: [SourceCandidate],
        yearMin: Int?,
        yearMax: Int?,
        mb: MusicBrainzLookup
    ) async -> [SourceCandidate] {
        guard yearMin != nil || yearMax != nil else { return candidates }
        let lo = yearMin ?? Int.min
        let hi = yearMax ?? Int.max

        var kept: [SourceCandidate] = []
        var unknownCount = 0
        for c in candidates {
            if let y = await mb.firstReleaseYear(artist: c.artist, title: c.title) {
                if y >= lo && y <= hi { kept.append(c) }
            } else {
                kept.append(c) // unknown → keep (fail-open)
                unknownCount += 1
            }
        }
        logger.info("era filter \(lo, privacy: .public)..\(hi, privacy: .public): \(candidates.count) → \(kept.count) (\(unknownCount, privacy: .public) unknown, kept fail-open)")
        return kept
    }

    // MARK: - Region filter (stage 7)

    public static func applyRegionFilter(
        _ candidates: [SourceCandidate],
        regions: [String],
        mb: MusicBrainzLookup
    ) async -> [SourceCandidate] {
        guard !regions.isEmpty else { return candidates }
        let allowed = Set(regions.map { $0.uppercased() })

        var kept: [SourceCandidate] = []
        // Dedup artist lookups — one MB call per unique artist, not per
        // track. Pipeline refills can have 3-5 tracks per artist easily.
        var artistCode: [String: String?] = [:]
        var unknownArtists: Set<String> = []

        for c in candidates {
            let key = c.artist.lowercased()
            let code: String?
            if let cached = artistCode[key] {
                code = cached
            } else {
                code = await mb.countryCode(forArtist: c.artist)
                artistCode[key] = .some(code)
            }
            if let code {
                if allowed.contains(code.uppercased()) { kept.append(c) }
            } else {
                kept.append(c) // unknown → keep (fail-open)
                unknownArtists.insert(key)
            }
        }
        logger.info("region filter \(allowed.sorted().joined(separator: ","), privacy: .public): \(candidates.count) → \(kept.count) (\(unknownArtists.count, privacy: .public) unknown artists, kept fail-open)")
        return kept
    }
}
#endif
