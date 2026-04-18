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
#endif
