import Foundation
import SwiftUI

/// Drives ``LibraryView`` by running a ``LibraryIndexer`` scan and publishing
/// the resulting playlists, loading state, and any error.
///
/// The view model exposes:
/// - `playlists` — the full set of grouped playlists (All Songs, Loose
///   Tracks if present, then folder playlists A–Z).
/// - `selectedPlaylistID` — the currently-selected playlist's id. Defaults
///   to the first playlist (All Songs) after a successful load.
/// - `selectedPlaylist` — computed convenience for the currently-selected
///   playlist, falling back to the first playlist if nothing is selected.
/// - `tracks` — computed convenience returning the selected playlist's
///   tracks, so existing callers (e.g. ``LibraryView``'s flat list) keep
///   working until the sidebar lands in Task 1.9.
///
/// `@MainActor` because it publishes UI state. Deliberately narrow: no
/// persistence, no hot-reload, no file-system notifications — just "given a
/// folder, produce playlists". Wider behaviour can layer on in later tasks.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public private(set) var playlists: [Playlist] = []
    @Published public var selectedPlaylistID: Playlist.ID?
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let indexer: LibraryIndexer

    public init(indexer: LibraryIndexer = LibraryIndexer()) {
        self.indexer = indexer
    }

    /// The playlist currently selected in the UI, or the first playlist
    /// (All Songs) when nothing is explicitly selected.
    public var selectedPlaylist: Playlist? {
        if let id = selectedPlaylistID,
           let match = playlists.first(where: { $0.id == id }) {
            return match
        }
        return playlists.first
    }

    /// The tracks of the currently-selected playlist. Kept around so the
    /// existing flat-list ``LibraryView`` can render "All Songs" without
    /// knowing about playlists yet. Task 1.9 will introduce a sidebar.
    public var tracks: [Track] {
        selectedPlaylist?.tracks ?? []
    }

    /// Scan `folder` and publish the results. On failure, clears
    /// `playlists` and populates `error` with a user-presentable description.
    public func load(from folder: URL) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await indexer.scan(folder: folder)
            self.playlists = loaded
            // Reset selection to the first playlist ("All Songs") so the
            // UI always has a sensible default after a load.
            self.selectedPlaylistID = loaded.first?.id
        } catch {
            self.error = error.localizedDescription
            self.playlists = []
            self.selectedPlaylistID = nil
        }
    }
}
