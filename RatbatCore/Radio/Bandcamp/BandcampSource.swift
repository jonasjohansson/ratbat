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
            return .generative(
                url: track.cachedURL,
                artist: track.artist,
                title: track.title,
                album: track.album,
                duration: track.duration,
                artworkURL: track.artworkURL,
                sourceURL: track.sourceURL,
                // Bandcamp resolves by direct URL, so the resolver's id is
                // a synthetic `"bandcamp…:<slug>"`. `generative` filters it
                // out rather than minting a YouTube link that 404s.
                youtubeID: track.youtubeID,
                origin: .bandcamp,
                historyID: track.historyID
            )
        } catch let error as BandcampStationController.Error where error.endsStation {
            // `nil` means "this station is over" to the encode loop, so
            // only genuine end-of-supply may collapse to it. A transient
            // failure is deliberately NOT caught here: it propagates as a
            // thrown error, which the encode loop retries with backoff.
            return nil
        }
    }
}
#endif
