import Foundation

/// A named collection of ``Track`` values, typically derived from a
/// top-level subfolder of the user's music library.
///
/// Three kinds exist:
/// - ``Kind/folder`` — a real on-disk subfolder of the library root.
/// - ``Kind/allSongs`` — a synthetic union of every track in the library.
/// - ``Kind/looseTracks`` — audio files sitting directly in the root
///   (not inside any subfolder).
///
/// `Sendable` + `Hashable` + `Identifiable` so the type is trivially usable
/// across actor boundaries, as `List` selection values, and in `Set`s /
/// dictionary keys.
public struct Playlist: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    /// Source folder on disk, or `nil` for synthetic playlists such as
    /// "All Songs".
    public let folder: URL?
    public let tracks: [Track]
    public let kind: Kind

    public enum Kind: Sendable, Hashable {
        case folder
        case allSongs
        case looseTracks
    }

    public init(
        id: UUID = UUID(),
        name: String,
        folder: URL?,
        tracks: [Track],
        kind: Kind
    ) {
        self.id = id
        self.name = name
        self.folder = folder
        self.tracks = tracks
        self.kind = kind
    }
}
