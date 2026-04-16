import Foundation

/// A radio station — a shuffled pool of tracks that can be broadcast.
///
/// v1 is UI + data-model only. A station is created from a source (currently
/// only a ``Playlist``) and carries its pre-shuffled queue so the detail
/// pane can render a stable order without reshuffling on every redraw.
/// Audio capture / streaming lands in Tasks 3.2–3.4 — this type deliberately
/// has no playback concept yet.
///
/// `Sendable` + `Hashable` + `Identifiable` + `Codable` matches ``Playlist``
/// and ``Track``, so stations compose cleanly with the existing library
/// types (selection tags, cache, cross-actor passing) as Phase 3 grows.
public struct Station: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var seed: Seed
    /// Pre-shuffled order. Built once at creation time so the detail pane
    /// stays stable across renders — reshuffling on each access would make
    /// row selection jump around.
    public var queue: [Track]

    /// Where a station's tracks came from. Kept as a sum type so future
    /// seeds (a folder, a manually assembled set, a smart rule) slot in
    /// without breaking existing stations on disk.
    public enum Seed: Hashable, Sendable, Codable {
        case playlist(sourceID: UUID, sourceName: String)
        case folder(path: URL)
        case manual
    }

    public init(id: UUID = UUID(), name: String, seed: Seed, queue: [Track]) {
        self.id = id
        self.name = name
        self.seed = seed
        self.queue = queue
    }

    /// Build a station seeded from a playlist. Auto-names as
    /// "Radio based on {playlist name}" so the sidebar immediately reads
    /// as what the user just did.
    public static func from(playlist: Playlist) -> Station {
        let shuffled = playlist.tracks.shuffled()
        return Station(
            name: "Radio based on \(playlist.name)",
            seed: .playlist(sourceID: playlist.id, sourceName: playlist.name),
            queue: shuffled
        )
    }
}
