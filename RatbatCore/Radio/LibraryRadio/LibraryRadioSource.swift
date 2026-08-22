#if os(macOS)
import Foundation

/// Wraps ``LibraryRadioStationController`` as a ``TrackSource``.
///
/// The playlist-source precedent for local files, not the LastFM one: the
/// controller hands back an owned ``Track`` whose URL already points at a
/// decodable file, so there is no resolver, no download wait, and no
/// transient-failure translation — the only error the controller can
/// throw is "the filtered library is empty", which maps to `nil` ("this
/// station is over") exactly like `poolExhausted` does for Last.fm.
///
/// **Boost steering is the protocol's default no-op here, on purpose.**
/// Generative sources re-aim a similar-artist expansion when the owner
/// boosts; this source has no expansion to re-aim — every candidate is
/// already owned. The boost still lands: it stamps affinity in the
/// history store, and the controller re-reads those signals at every
/// refill, so a boost tonight reweights tomorrow's lap. Overriding
/// ``TrackSource/noteSteeringChanged()`` to force an early refill would
/// only reshuffle the same owned tracks mid-lap.
public actor LibraryRadioSource: TrackSource {
    private let controller: LibraryRadioStationController
    /// Records the play and answers the history row id — the
    /// ``PlaylistSource`` closure shape, and for the same reason: the
    /// store is macOS-only state owned elsewhere, and the closure keeps
    /// this actor constructible without it.
    private let recordPlay: (@Sendable (String, String, URL) async -> Int64?)?

    public init(
        controller: LibraryRadioStationController,
        recordPlay: (@Sendable (String, String, URL) async -> Int64?)? = nil
    ) {
        self.controller = controller
        self.recordPlay = recordPlay
    }

    public func nextURL() async throws -> TrackSourceItem? {
        let track: Track
        do {
            track = try await controller.nextTrack()
        } catch is LibraryRadioStationController.Error {
            // Genuine end-of-supply — nothing in the library matches the
            // facets (or everything that does is skip-blacklisted). The
            // encode loop reads `nil` as "station over" and stands the
            // pipeline down cleanly.
            return nil
        }

        // Record the play so the owner's own records feed history and
        // taste exactly like every other station — the signals this
        // kind's next refill is built from.
        let historyID = await recordPlay?(
            track.artist.isEmpty ? "Unknown" : track.artist,
            track.title.isEmpty ? track.url.lastPathComponent : track.title,
            track.url
        )
        // Same wire posture as PlaylistSource: `origin: .library` (the
        // truth — the file is the owner's), owned so a ♥ records
        // affinity instead of re-copying a file it already has, and
        // empty tags become explicit nils.
        return TrackSourceItem(
            url: track.url,
            artist: track.artist.isEmpty ? nil : track.artist,
            title: track.title.isEmpty ? nil : track.title,
            album: track.album.isEmpty ? nil : track.album,
            duration: track.duration > 0 ? track.duration : nil,
            origin: .library,
            historyID: historyID,
            isOwned: true
        )
    }
}
#endif
