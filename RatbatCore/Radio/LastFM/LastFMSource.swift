#if os(macOS)
import Foundation

/// Wraps ``LastFMStationController`` as a ``TrackSource``. Resolves one
/// track at a time on demand — the broadcaster pauses while we fetch.
///
/// When the controller reports ``LastFMStationController/Error/poolExhausted``
/// or `.noTracksForTags` we surface that as `nil` so the broadcaster can
/// stop the pipeline cleanly instead of hard-failing. Other error kinds
/// propagate.
public actor LastFMSource: TrackSource {
    private let controller: LastFMStationController

    public init(controller: LastFMStationController) {
        self.controller = controller
    }

    public func nextURL() async throws -> TrackSourceItem? {
        do {
            let track = try await controller.nextTrack()
            return .generative(
                url: track.cachedURL,
                artist: track.artist,
                title: track.title,
                album: track.album,
                duration: track.duration,
                artworkURL: track.artworkURL,
                // Last.fm is a recommendation index, not a place a track
                // lives — the only URL in play is the YouTube Music match,
                // which is reported as `youtubeURL`, not as a source page.
                sourceURL: nil,
                youtubeID: track.youtubeID,
                origin: .lastFM,
                historyID: track.historyID
            )
        } catch LastFMStationController.Error.poolExhausted {
            return nil
        } catch LastFMStationController.Error.noTracksForTags {
            return nil
        }
    }
}
#endif
