#if os(macOS)
import SwiftUI

/// Top-level macOS view that decides between onboarding (folder picker) and
/// the library proper, based on whether ``LibraryConfig`` has a stored
/// music folder.
///
/// Spotify-style layout, wired in Task 1.9 and extended in Task 3.1 with a
/// "Stations" section in the sidebar:
/// - Sidebar: ``PlaylistsSidebarView`` showing the active radio station
///   (if any) plus every library playlist.
/// - Detail:  ``LibraryView`` of the currently selected playlist *or*
///   station — the sidebar selection is a ``SidebarSelection`` sum type
///   and the detail pane branches on the case.
/// - Bottom:  ``PlayerView`` bar that spans the whole window — deliberately
///   outside the split so it stays put as the user swaps sidebar/detail.
///
/// Owns the shared ``AudioPlayer``, the ``LibraryViewModel`` and the
/// ``StationManager`` for the window. Both observable objects are
/// `@StateObject` so they survive across library reloads and folder
/// changes. The unified sidebar selection (`sidebarSelection`) lives here
/// too — we mirror playlist selections back into `libraryVM` to preserve
/// the existing `selectedPlaylistID` contract that tests still rely on.
/// iOS uses a different entry point (no folder picker, no bottom player
/// bar, no split view), so this view is macOS-only.
public struct RootView: View {
    @State private var musicFolder: URL?
    @StateObject private var player = AudioPlayer()
    @StateObject private var libraryVM = LibraryViewModel()
    @StateObject private var stations = StationManager()
    @State private var sidebarSelection: SidebarSelection?
    /// Owned by the view so it lives as long as the window does. Held as
    /// optional `@State` because we can't `@StateObject` a non-
    /// `ObservableObject`, and we want to construct it *after* `player`
    /// is guaranteed to exist (first `onAppear`).
    @State private var nowPlaying: NowPlayingController?
    private let config: LibraryConfig

    public init(config: LibraryConfig = LibraryConfig()) {
        self.config = config
        self._musicFolder = State(initialValue: config.musicFolder)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                if let folder = musicFolder {
                    NavigationSplitView {
                        PlaylistsSidebarView(
                            vm: libraryVM,
                            stations: stations,
                            selection: $sidebarSelection
                        )
                        .frame(minWidth: 180)
                    } detail: {
                        detailView
                    }
                    .task(id: folder) { await libraryVM.load(from: folder) }
                    // Mirror the unified sidebar selection back into the
                    // library view model so anything still reading
                    // `selectedPlaylistID` (tests, the selected-playlist
                    // computed convenience) stays in sync.
                    .onChange(of: sidebarSelection) { _, newSel in
                        if case let .playlist(id) = newSel {
                            libraryVM.selectedPlaylistID = id
                        }
                    }
                    // When the library finishes loading and picks a default
                    // playlist, hoist that into the sidebar selection so the
                    // detail pane has something to render on first launch.
                    .onChange(of: libraryVM.selectedPlaylistID) { _, newID in
                        if sidebarSelection == nil, let id = newID {
                            sidebarSelection = .playlist(id)
                        }
                    }
                } else {
                    FolderPickerView { url in
                        config.musicFolder = url
                        musicFolder = url
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // Only show the player bar once we're past folder-picking.
            // Sits outside the split so it spans the whole window.
            if musicFolder != nil {
                Divider()
                PlayerView(player: player)
            }
        }
        .onAppear {
            if nowPlaying == nil {
                nowPlaying = NowPlayingController(player: player)
            }
        }
    }

    @ViewBuilder private var detailView: some View {
        if libraryVM.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                // Task 1.14: phase-aware caption — Phase 1 shows a running
                // folder/file count with no denominator (total isn't known
                // until the tree walk finishes), Phase 2 switches to the
                // familiar "X / Y tracks" ratio, and the nil case (the
                // instant between starting and the first callback, or a
                // cache miss path that hasn't emitted yet) falls back to a
                // generic caption so the UI is never silent.
                Group {
                    switch libraryVM.scanPhase {
                    case .discovering(let folders, let files):
                        Text("Discovering files… \(folders) folders, \(files) tracks")
                    case .loading(let processed, let total):
                        Text("Loading metadata… \(processed) / \(total) tracks")
                    case nil:
                        Text("Scanning library…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = libraryVM.error {
            VStack(spacing: 12) {
                Text("Couldn't read library").font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let playlist = resolvedDetailPlaylist {
            LibraryView(playlist: playlist) { tracks, startIndex in
                // Queue the whole playlist and start from the picked
                // track so prev/next (and media keys) traverse the
                // full list rather than bouncing on a one-track queue.
                player.play(queue: tracks, startingAt: startIndex)
            }
        } else {
            Text("Select a playlist")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Resolves the current sidebar selection into a ``Playlist`` for the
    /// detail pane. Stations are rendered by synthesising a transient
    /// playlist from the station's queue — ``LibraryView`` already knows
    /// how to draw a playlist, so this keeps the detail pane single-purpose
    /// while the sidebar handles the concept split.
    ///
    /// Falls back to the library VM's selected playlist when there's no
    /// explicit sidebar selection yet (first-launch state, before the
    /// load-triggered mirroring kicks in).
    private var resolvedDetailPlaylist: Playlist? {
        switch sidebarSelection {
        case .some(.station(let id)):
            if let station = stations.activeStation, station.id == id {
                return station.asPlaylist()
            }
            return nil
        case .some(.playlist(let id)):
            return libraryVM.playlists.first(where: { $0.id == id })
                ?? libraryVM.selectedPlaylist
        case .none:
            return libraryVM.selectedPlaylist
        }
    }
}

private extension Station {
    /// Render a station as a transient ``Playlist`` so ``LibraryView`` can
    /// display it without a second code path. The queue is already
    /// shuffle-ordered — re-sorting would defeat the station concept — so
    /// `LibraryView`'s default sort by title is fine for v1; the user can
    /// still sort manually. Reuses the station's `id` as the playlist id
    /// so selection continues to resolve if we round-trip the value.
    func asPlaylist() -> Playlist {
        Playlist(
            id: id,
            name: name,
            folder: nil,
            tracks: queue,
            children: [],
            kind: .folder
        )
    }
}
#endif
