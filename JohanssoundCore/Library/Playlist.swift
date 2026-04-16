import Foundation

/// A named collection of ``Track`` values, typically derived from a folder in
/// the user's music library.
///
/// Three kinds exist:
/// - ``Kind/folder`` — a real on-disk folder of the library (at any depth).
/// - ``Kind/allSongs`` — a synthetic union of every track in the library.
/// - ``Kind/looseTracks`` — audio files sitting directly in the root
///   (not inside any subfolder).
///
/// For folder-kind playlists, ``tracks`` is the *union* of every audio file
/// discovered anywhere under the folder (direct children plus all
/// descendants). ``children`` holds the direct sub-folder playlists so the
/// sidebar can render the tree with `DisclosureGroup`s.
///
/// `Sendable` + `Hashable` + `Identifiable` so the type is trivially usable
/// across actor boundaries, as `List` selection values, and in `Set`s /
/// dictionary keys. The recursive `children: [Playlist]` stays Hashable via
/// Swift's copy-on-write for value-type arrays — auto-synthesis handles it.
public struct Playlist: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let name: String
    /// Source folder on disk, or `nil` for synthetic playlists such as
    /// "All Songs".
    public let folder: URL?
    /// For folder playlists, the union of all descendant tracks (direct files
    /// plus everything under every sub-folder). For ``Kind/allSongs`` and
    /// ``Kind/looseTracks``, the usual flat list.
    public let tracks: [Track]
    /// Direct sub-folder playlists — used to render a hierarchical sidebar.
    /// Leaf folders have an empty array. Synthetic kinds never have children.
    public let children: [Playlist]
    public let kind: Kind

    public enum Kind: Sendable, Hashable, Codable {
        case folder
        case allSongs
        case looseTracks
    }

    public init(
        id: UUID = UUID(),
        name: String,
        folder: URL?,
        tracks: [Track],
        children: [Playlist] = [],
        kind: Kind
    ) {
        self.id = id
        self.name = name
        self.folder = folder
        self.tracks = tracks
        self.children = children
        self.kind = kind
    }
}
