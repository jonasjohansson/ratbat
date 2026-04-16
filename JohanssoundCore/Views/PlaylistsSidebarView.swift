#if os(macOS)
import SwiftUI

/// Sidebar list of playlists for the Spotify-style macOS layout.
///
/// Displays every playlist published by ``LibraryViewModel``. Folder
/// playlists whose ``Playlist/children`` is non-empty render as
/// `DisclosureGroup`s so the user can drill into sub-folders — the label
/// itself is still tagged for selection, so clicking the folder name (not
/// just the triangle) selects that folder's union-playlist.
///
/// Root order, guaranteed by the indexer:
/// 1. "All Songs" pinned to the top.
/// 2. "Loose Tracks" next, when the library root contains audio files
///    sitting outside any subfolder.
/// 3. Top-level folder playlists A–Z after that.
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
                node(playlist)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
    }

    /// Renders one playlist node. Leaves show as a plain row; folders with
    /// children show as a `DisclosureGroup` that recursively renders each
    /// child via ``node(_:)`` again. The `.tag(playlist.id)` on the group
    /// itself means clicking the folder label selects that playlist in
    /// addition to toggling the disclosure state.
    ///
    /// Returned as ``AnyView`` because Swift's opaque-type inference can't
    /// close the loop on a recursively-called `some View` function — the
    /// return type would be defined in terms of itself. Type-erasing here
    /// is the standard workaround and the perf cost is immaterial at
    /// sidebar-row scale.
    private func node(_ playlist: Playlist) -> AnyView {
        if playlist.children.isEmpty {
            return AnyView(
                row(playlist)
                    .tag(playlist.id)
            )
        } else {
            return AnyView(
                DisclosureGroup {
                    ForEach(playlist.children) { child in
                        node(child)
                    }
                } label: {
                    row(playlist)
                }
                .tag(playlist.id)
            )
        }
    }

    @ViewBuilder
    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: playlist.kind, hasChildren: !playlist.children.isEmpty))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(playlist.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(playlist.tracks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func iconName(for kind: Playlist.Kind, hasChildren: Bool) -> String {
        switch kind {
        case .allSongs:    return "music.note.list"
        case .looseTracks: return "music.note"
        case .folder:      return hasChildren ? "folder" : "music.note.list"
        }
    }
}
#endif
