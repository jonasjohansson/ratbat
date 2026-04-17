import Foundation

/// Wraps a static ``[Track]`` queue; loops forever matching the
/// pre-refactor behaviour of ``RadioBroadcaster``. Returning `nil` is
/// reserved for the genuinely empty case — a single-track queue will
/// keep handing back that same track on every call.
public actor PlaylistSource: TrackSource {
    private let tracks: [Track]
    private var cursor: Int = 0

    public init(tracks: [Track]) {
        self.tracks = tracks
    }

    public func nextURL() async throws -> TrackSourceItem? {
        guard !tracks.isEmpty else { return nil }
        let track = tracks[cursor % tracks.count]
        cursor += 1
        return TrackSourceItem(
            url: track.url,
            artist: track.artist,
            title: track.title,
            historyID: nil
        )
    }
}
