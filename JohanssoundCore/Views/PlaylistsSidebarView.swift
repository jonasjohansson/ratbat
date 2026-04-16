#if os(macOS)
import SwiftUI

/// Sidebar list of playlists for the Spotify-style macOS layout.
///
/// Displays every playlist published by ``LibraryViewModel`` — in indexer
/// order, which guarantees:
/// 1. "All Songs" pinned to the top.
/// 2. "Loose Tracks" next, when the library root contains audio files
///    sitting outside any subfolder.
/// 3. Folder playlists A–Z after that.
///
/// Selection is bound to `vm.selectedPlaylistID`, so tapping a row swaps the
/// detail view in ``RootView`` without any extra glue. Each row shows an
/// SF Symbol that reflects the playlist `kind`, the name, and a
/// right-aligned track count for quick scanning.
public struct PlaylistsSidebarView: View {
    @ObservedObject public var vm: LibraryViewModel

    public init(vm: LibraryViewModel) {
        self.vm = vm
    }

    public var body: some View {
        List(selection: $vm.selectedPlaylistID) {
            ForEach(vm.playlists) { playlist in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: playlist.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(playlist.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(playlist.tracks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .tag(playlist.id)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
    }

    private func iconName(for kind: Playlist.Kind) -> String {
        switch kind {
        case .allSongs:    return "music.note.list"
        case .looseTracks: return "music.note"
        case .folder:      return "folder"
        }
    }
}
#endif
