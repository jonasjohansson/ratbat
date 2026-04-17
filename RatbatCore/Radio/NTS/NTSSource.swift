#if os(macOS)
import Foundation

/// Wraps ``NTSStationController`` as a ``TrackSource``. Resolves one
/// track at a time on demand — the broadcaster pauses while we fetch.
///
/// When the controller reports ``NTSStationController/Error/poolExhausted``
/// (no more unseen tracklists and no more shows to scrape for the
/// configured tags) we surface that as `nil` so the broadcaster can
/// stop the pipeline cleanly instead of hard-failing.
public actor NTSSource: TrackSource {
    private let controller: NTSStationController

    public init(controller: NTSStationController) {
        self.controller = controller
    }

    public func nextURL() async throws -> TrackSourceItem? {
        do {
            let track = try await controller.nextTrack()
            return TrackSourceItem(
                url: track.cachedURL,
                artist: track.artist,
                title: track.title,
                historyID: track.historyID
            )
        } catch NTSStationController.Error.poolExhausted {
            return nil
        }
    }
}
#endif
