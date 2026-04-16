import Foundation

/// A single audio file discovered by the library indexer.
///
/// `Sendable` so we can pass instances across actor boundaries in later
/// tasks (playback queue, background scan, etc.) under Swift 6 strict
/// concurrency without having to wrap them in `@unchecked`.
public struct Track: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}
