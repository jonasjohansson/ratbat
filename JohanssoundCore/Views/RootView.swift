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
    private let config: LibraryConfig

    public init(config: LibraryConfig = LibraryConfig()) {
        self.config = config
        self._musicFolder = State(initialValue: config.musicFolder)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                if let folder = musicFolder {
                    LibraryView(folder: folder) { track in
                        // v1: play a single track. Task 1.7 will switch
                        // this to queue-up-the-whole-list-and-start-here.
                        player.play(track)
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
    }
}
#endif
