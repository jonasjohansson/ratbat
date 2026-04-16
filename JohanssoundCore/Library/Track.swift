import Foundation

/// A single audio file discovered by the library indexer.
///
/// `Sendable` so we can pass instances across actor boundaries in later
/// tasks (playback queue, background scan, etc.) under Swift 6 strict
/// concurrency without having to wrap them in `@unchecked`.
///
/// Extended in Task 1.12 with optional metadata fields — most ID3/iTunes
/// tag types, plus a couple of file-system facts (size, added-date) we can
/// read cheaply while we've already got a `URL` in hand. Everything beyond
/// the original five fields is optional (or zero-defaulted) because our
/// test fixtures have no embedded metadata, and even production files can
/// be missing any given tag.
public struct Track: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval

    // Extended metadata — optional because not every file has them.
    public let trackNumber: Int?
    public let year: Int?
    public let genre: String?
    /// Audio stream bitrate in **kbps**. `nil` when we can't derive one
    /// (e.g. some formats report `estimatedDataRate` as 0).
    public let bitrate: Int?
    /// File size in bytes. 0 when the resource value couldn't be read.
    public let fileSize: Int64
    /// When the track entered the library — best-effort, using the file's
    /// `.addedToDirectoryDate` when available and falling back to the
    /// content modification date. Defaults to "now" for hand-constructed
    /// `Track` values (tests, previews) so code that doesn't care still
    /// gets a sensible value.
    public let dateAdded: Date

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        trackNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        bitrate: Int? = nil,
        fileSize: Int64 = 0,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.trackNumber = trackNumber
        self.year = year
        self.genre = genre
        self.bitrate = bitrate
        self.fileSize = fileSize
        self.dateAdded = dateAdded
    }
}
