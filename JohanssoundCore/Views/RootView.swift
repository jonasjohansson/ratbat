#if os(macOS)
import SwiftUI

/// Top-level macOS view that decides between onboarding (folder picker) and
/// the library proper, based on whether ``LibraryConfig`` has a stored
/// music folder.
///
/// Owns a single ``LibraryConfig`` instance and the shared ``AudioPlayer``
/// for the app instance. The player is held as `@StateObject` so it
/// persists across library reloads and folder changes. iOS uses a
/// different entry point (no folder picker, no bottom player bar), so
/// this view is macOS-only.
public struct RootView: View {
    @State private var musicFolder: URL?
    @StateObject private var player = AudioPlayer()
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
                    LibraryView(folder: folder) { tracks, startIndex in
                        // Queue the whole library and start from the picked
                        // track so prev/next (and media keys) traverse the
                        // full list rather than bouncing on a one-track queue.
                        player.play(queue: tracks, startingAt: startIndex)
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
}
#endif
