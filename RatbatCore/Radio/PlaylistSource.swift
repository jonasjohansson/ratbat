import Foundation

/// Wraps a static ``[Track]`` queue and loops forever. By default the
/// queue is shuffled on init and **reshuffled after every full pass**, so
/// each broadcast start picks a fresh random order rather than replaying
/// the same sequence from the same first track every time. Pass
/// `shuffle: false` for deterministic, source-order playback (used by
/// tests and any caller that wants a fixed queue).
///
/// Returning `nil` is reserved for the genuinely empty case — a
/// single-track queue keeps handing back that same track on every call.
public actor PlaylistSource: TrackSource {
    private let shuffle: Bool
    private var order: [Track]
    private var cursor: Int = 0
    /// Records a play and hands back its history row id. A closure, not
    /// a `HistoryStore`: the store is macOS-only and this type is
    /// cross-platform — passing the store itself is the exact shape that
    /// broke the iOS build once. nil on iOS and in tests.
    private let recordPlay: (@Sendable (String, String, URL) async -> Int64?)?

    public init(
        tracks: [Track],
        shuffle: Bool = true,
        recordPlay: (@Sendable (String, String, URL) async -> Int64?)? = nil
    ) {
        self.shuffle = shuffle
        self.order = shuffle ? tracks.shuffled() : tracks
        self.recordPlay = recordPlay
    }

    public func nextURL() async throws -> TrackSourceItem? {
        guard !order.isEmpty else { return nil }

        if cursor >= order.count {
            // Completed a full pass. Reshuffle for the next lap so the
            // station doesn't repeat the same order forever, and nudge the
            // seam so a track can't immediately repeat across the wrap.
            if shuffle && order.count > 1 {
                let last = order[order.count - 1]
                order.shuffle()
                if order[0].url == last.url, let swap = order.indices.dropFirst().first {
                    order.swapAt(0, swap)
                }
            }
            cursor = 0
        }

        let track = order[cursor]
        cursor += 1
        // Record the play so your OWN library feeds the same history and
        // taste signals as generative stations. Before this, listening to
        // your own records taught Ratbat nothing and left the history
        // view blank for the station you play most.
        let historyID = await recordPlay?(
            track.artist ?? "Unknown",
            track.title ?? track.url.lastPathComponent,
            track.url
        )
        return TrackSourceItem(
            url: track.url,
            artist: track.artist,
            title: track.title,
            historyID: historyID,
            isOwned: true
        )
    }
}
