#if os(macOS)
import SwiftUI

/// Sidebar list for the Spotify-style macOS layout.
///
/// Two sections:
/// 1. **Stations** — shown only when ``StationManager/activeStation`` is
///    non-nil (v1 allows a single active station at a time). Selecting it
///    swaps the detail pane to the station's shuffled queue.
/// 2. **Library** — every playlist published by ``LibraryViewModel``.
///    Folder playlists whose ``Playlist/children`` is non-empty render as
///    `DisclosureGroup`s so the user can drill into sub-folders — the label
///    itself is still tagged for selection, so clicking the folder name
///    (not just the triangle) selects that folder's union-playlist.
///
/// Library root order, guaranteed by the indexer:
/// 1. "All Songs" pinned to the top.
/// 2. "Loose Tracks" next, when the library root contains audio files
///    sitting outside any subfolder.
/// 3. Top-level folder playlists A–Z after that.
///
/// Selection is a ``SidebarSelection`` sum type bound from the parent so
/// the detail pane can branch on playlist-vs-station without the sidebar
/// having to care about detail rendering. Each library row shows an SF
/// Symbol reflecting the playlist `kind`, the name, and a right-aligned
/// track count; the station row uses an antenna icon.
///
/// Right-clicking a playlist row offers "Create Station from this" —
/// builds a shuffled station seeded from that playlist (replacing the
/// current one) and auto-selects it in the detail pane.
public struct PlaylistsSidebarView: View {
    @ObservedObject public var vm: LibraryViewModel
    @ObservedObject public var stations: StationManager
    @ObservedObject public var radio: RadioBroadcaster
    @Binding public var selection: SidebarSelection?

    public init(
        vm: LibraryViewModel,
        stations: StationManager,
        radio: RadioBroadcaster,
        selection: Binding<SidebarSelection?>
    ) {
        self.vm = vm
        self.stations = stations
        self.radio = radio
        self._selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            if let station = stations.activeStation {
                Section("Stations") {
                    stationRow(station)
                        .tag(SidebarSelection.station(station.id))
                }
            }

            Section("Library") {
                ForEach(vm.playlists) { playlist in
                    node(playlist)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
    }

    /// Renders one playlist node. Leaves show as a plain row; folders with
    /// children show as a `DisclosureGroup` that recursively renders each
    /// child via ``node(_:)`` again. The `.tag(...)` on the group itself
    /// means clicking the folder label selects that playlist in addition
    /// to toggling the disclosure state.
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
                    .tag(SidebarSelection.playlist(playlist.id))
                    .contextMenu { playlistContextMenu(playlist) }
            )
        } else {
            return AnyView(
                DisclosureGroup {
                    ForEach(playlist.children) { child in
                        node(child)
                    }
                } label: {
                    row(playlist)
                        .contextMenu { playlistContextMenu(playlist) }
                }
                .tag(SidebarSelection.playlist(playlist.id))
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

    @ViewBuilder
    private func stationRow(_ station: Station) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: radio.isBroadcasting
                    ? "antenna.radiowaves.left.and.right.circle.fill"
                    : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(radio.isBroadcasting ? .red : .secondary)
                    .frame(width: 16)
                Text(station.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(station.queue.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            // Task 3.2: when broadcasting, surface the stream URL so the
            // user can aim VLC at it without digging through logs.
            if radio.isBroadcasting, let url = radio.currentURL {
                Text(url.absoluteString)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            }
        }
    }

    /// Right-click menu on any playlist row. v1 only offers station
    /// creation; more actions (rescan a single folder, reveal in Finder,
    /// etc.) can slot in here without affecting selection wiring.
    @ViewBuilder
    private func playlistContextMenu(_ playlist: Playlist) -> some View {
        Button("Create Station from this") {
            stations.createStation(from: playlist)
            if let id = stations.activeStation?.id {
                selection = .station(id)
            }
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
