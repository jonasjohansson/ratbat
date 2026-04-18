#if os(macOS)
import Foundation

/// Wraps ``BandcampStationController`` as a ``TrackSource``. Resolves one
/// track at a time on demand — the broadcaster pauses while we fetch.
///
/// When the controller reports ``BandcampStationController/Error/poolExhausted``
/// or `.noTracksForTags` we surface that as `nil` so the broadcaster can
/// stop the pipeline cleanly instead of hard-failing. Other error kinds
/// propagate. Mirrors ``LastFMSource`` by design.
public actor BandcampSource: TrackSource {
    private let controller: BandcampStationController

    public init(controller: BandcampStationController) {
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
        } catch BandcampStationController.Error.poolExhausted {
            return nil
        } catch BandcampStationController.Error.noTracksForTags {
            return nil
        }
    }
}
#endif
