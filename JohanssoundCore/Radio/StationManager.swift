import Foundation
import SwiftUI

/// Unified sidebar selection — the sidebar now holds both playlists (the
/// library) and a station, so a plain `Playlist.ID?` no longer spans the
/// full selection space. Kept a flat sum type so `List(selection:)` can use
/// it directly; `Hashable` is the only requirement SwiftUI imposes.
public enum SidebarSelection: Hashable, Sendable {
    case playlist(Playlist.ID)
    case station(Station.ID)
}

/// Owns the currently-active station.
///
/// v1: at most one active station at a time; no persistence; no audio
/// capture yet. Creating a new station replaces whatever was there —
/// simpler than juggling a list while we haven't settled the UX for
/// switching between saved stations.
///
/// `@MainActor` because it publishes UI state and is read straight from
/// SwiftUI views via `@ObservedObject`. Future work: persist active
/// station(s) to disk, allow multiple saved stations, and broadcast the
/// station's queue through the audio tap (Tasks 3.2+).
@MainActor
public final class StationManager: ObservableObject {
    @Published public private(set) var activeStation: Station?

    public init() {}

    /// Create a station from `playlist` and make it the active one,
    /// replacing any previously-active station.
    public func createStation(from playlist: Playlist) {
        activeStation = Station.from(playlist: playlist)
    }

    /// Drop the active station. Not wired to any UI in v1, but kept so
    /// tests (and a future "Remove Station" menu item) have a clean path.
    public func clear() {
        activeStation = nil
    }
}
