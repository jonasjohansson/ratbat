#if os(macOS)
import SwiftUI

/// Top-level macOS view that decides between onboarding (folder picker) and
/// the library proper, based on whether ``LibraryConfig`` has a stored
/// music folder.
///
/// Owns a single ``LibraryConfig`` instance. iOS uses a different entry
/// point (no folder picker), so this view is macOS-only.
public struct RootView: View {
    @State private var musicFolder: URL?
    private let config: LibraryConfig

    public init(config: LibraryConfig = LibraryConfig()) {
        self.config = config
        self._musicFolder = State(initialValue: config.musicFolder)
    }

    public var body: some View {
        Group {
            if let folder = musicFolder {
                LibraryView(folder: folder)
            } else {
                FolderPickerView { url in
                    config.musicFolder = url
                    musicFolder = url
                }
            }
        }
    }
}
#endif
