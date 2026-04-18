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
/// - `scanPhase` — optional ``ScanPhase``, non-nil only while an actual
///   scan is running. Task 1.14 replaced the flat `(current, total)` tuple
///   with a phase so the UI can distinguish "discovering X folders, Y
///   tracks" (no denominator yet) from "loading X / Y tracks" (Phase 2).
///
/// `@MainActor` because it publishes UI state. Deliberately narrow: no
/// persistence beyond the indexer cache, no hot-reload, no file-system
/// notifications — just "given a folder, produce playlists". Wider
/// behaviour can layer on in later tasks.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public private(set) var playlists: [Playlist] = []
    @Published public var selectedPlaylistID: Playlist.ID?
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    /// The track currently highlighted in the detail list. Lifted out of
    /// ``LibraryView``'s private `@State` so sibling UI — notably the
    /// Inspector pane on macOS — can render metadata for the same selection.
    /// `LibraryView` still owns the mechanics (List selection, arrow keys,
    /// double-click to play); it just mirrors the picked track here whenever
    /// the row selection changes.
    @Published public var selectedTrack: Track?
    /// Whether the macOS Inspector pane is open. Defaults closed — it's
    /// an opt-in deep-dive (right-click a track → Get Info, or ⌘I)
    /// rather than a follow-the-selection sidebar. Wiring it to every
    /// selection change made list-click latency noticeable on larger
    /// libraries; keeping it opt-in avoids that cost. Published so the
    /// toolbar button, context-menu "Get Info", and `.inspector(isPresented:)`
    /// binding on `RootView` all share one source of truth.
    @Published public var isInspectorOpen: Bool = false
    /// Current scan phase, published during a scan. Nil at rest and while a
    /// cache hit short-circuits the scan — cache loads are instant, so
    /// there's nothing to report. The UI switches the caption based on the
    /// case: "Discovering files… X folders, Y tracks" during `.discovering`,
    /// "Loading metadata… X / Y tracks" during `.loading`.
    @Published public private(set) var scanPhase: ScanPhase?

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
    ///
    /// Cache behaviour (Task 1.13): if a valid `.ratbat-cache.json`
    /// sits at the root, load it and short-circuit — no rescan. This
    /// trades freshness for a near-instant second launch; the user can
    /// force a fresh scan via ``rescan(folder:)``. If the cache is missing,
    /// corrupt, or from an incompatible version, we fall through to a full
    /// parallel scan and write the cache at the end so the next launch
    /// benefits.
    public func load(from folder: URL) async {
        isLoading = true
        error = nil
        scanPhase = nil
        defer {
            isLoading = false
            scanPhase = nil
        }

        // Fast path: use cached playlists if one exists and decodes cleanly.
        // v1 doesn't validate freshness — the user manually refreshes via
        // `rescan(folder:)` when the library changes on disk.
        if let cached = try? CacheStore.load(for: folder), !cached.isEmpty {
            self.playlists = cached
            self.selectedPlaylistID = cached.first?.id
            return
        }

        // Slow path: full scan, with progress reported into `scanPhase`.
        do {
            let loaded = try await indexer.scan(folder: folder) { [weak self] phase in
                self?.scanPhase = phase
            }
            self.playlists = loaded
            self.selectedPlaylistID = loaded.first?.id
            // Best-effort cache write — a failure here shouldn't disrupt
            // the load. The root might be read-only (e.g. a mounted DMG),
            // and that's fine; we just pay for a full scan next time.
            try? CacheStore.save(loaded, for: folder)
        } catch {
            self.error = error.localizedDescription
            self.playlists = []
            self.selectedPlaylistID = nil
        }
    }

    /// Force a fresh scan: wipe the on-disk cache and re-run ``load(from:)``.
    /// Intended for a future "Rescan Library" menu item. Leaving it here
    /// now keeps the ViewModel's contract complete for callers that want
    /// to bypass the cache without poking `CacheStore` themselves.
    public func rescan(folder: URL) async {
        try? CacheStore.delete(for: folder)
        await load(from: folder)
    }
}
