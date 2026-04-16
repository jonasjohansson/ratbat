#if os(macOS)
import SwiftUI

/// Top-level macOS view that decides between onboarding (folder picker) and
/// the library proper, based on whether ``LibraryConfig`` has a stored
/// music folder.
///
/// Spotify-style layout, wired in Task 1.9:
/// - Sidebar: ``PlaylistsSidebarView`` showing every playlist (All Songs,
///   Loose Tracks, then folders A–Z).
/// - Detail:  ``LibraryView`` of the currently selected playlist.
/// - Bottom:  ``PlayerView`` bar that spans the whole window — deliberately
///   outside the split so it stays put as the user swaps sidebar/detail.
///
/// Owns the shared ``AudioPlayer`` *and* the ``LibraryViewModel`` for the
/// window (promoted from ``LibraryView`` in Task 1.9 so the sidebar and
/// detail share one source of truth). Both are `@StateObject` so they
/// survive across library reloads and folder changes. iOS uses a different
/// entry point (no folder picker, no bottom player bar, no split view), so
/// this view is macOS-only.
public struct RootView: View {
    @State private var musicFolder: URL?
    @StateObject private var player = AudioPlayer()
    @StateObject private var libraryVM = LibraryViewModel()
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
                        PlaylistsSidebarView(vm: libraryVM)
                            .frame(minWidth: 180)
                    } detail: {
                        detailView
                    }
                    .task(id: folder) { await libraryVM.load(from: folder) }
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
            VStack(spacing: 8) {
                ProgressView()
                if let progress = libraryVM.scanProgress {
                    // Task 1.13: concrete "X / Y tracks" instead of a
                    // generic spinner so the user can see forward motion
                    // on big libraries where the scan takes real time.
                    Text("Scanning \(progress.current) / \(progress.total) tracks…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scanning library…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        } else if let playlist = libraryVM.selectedPlaylist {
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
}
#endif
