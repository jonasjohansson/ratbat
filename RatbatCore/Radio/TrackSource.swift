import Foundation

/// Abstract supplier of "play this audio file next" URLs for the
/// broadcaster. Two concrete impls ship with Ratbat:
///
///   * ``PlaylistSource`` — a static queue, looped forever
///   * ``NTSSource`` — a live generative feed curated from NTS Radio
///
/// Sources are async because NTS-style feeds need to scrape + download
/// before they can hand back a URL. Returning `nil` means "no more
/// tracks available right now" — the broadcaster will stop the pipeline
/// (it's fine to restart from the top later).
public protocol TrackSource: Actor {
    /// Next audio file URL to play, or nil if the source is exhausted.
    /// May take a noticeable amount of time (download-on-demand).
    func nextURL() async throws -> TrackSourceItem?
}

/// Metadata-bearing handle to the next track a ``TrackSource`` hands
/// the broadcaster. URL points at a local, decodable file; the string
/// fields feed ICY and the "Now:" UI snippet.
public struct TrackSourceItem: Sendable {
    public let url: URL
    /// Human-readable metadata for ICY and logs. `nil` fields are fine.
    public let artist: String?
    public let title: String?
    /// History row id, when the play was recorded. Since the history
    /// slice this is populated for playlist sources too, so it no longer
    /// doubles as "is this a transient download?" — see ``isOwned``.
    public let historyID: Int64?
    /// True when `url` points at a file already in the user's library
    /// (playlist sources), false for transient cache downloads awaiting
    /// a ♥. Decides whether ♥ copies a file or just records affinity;
    /// previously inferred from `historyID == nil`, which stopped being
    /// true once playlist plays started being recorded.
    public let isOwned: Bool

    public init(
        url: URL,
        artist: String? = nil,
        title: String? = nil,
        historyID: Int64? = nil,
        isOwned: Bool = false
    ) {
        self.url = url
        self.artist = artist
        self.title = title
        self.historyID = historyID
        self.isOwned = isOwned
    }
}
