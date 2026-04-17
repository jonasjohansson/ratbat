#if os(macOS)
import AppKit
import SwiftUI

/// Sidebar list for the Spotify-style macOS layout.
///
/// Two sections:
/// 1. **Stations** — every user-created ``Station`` in
///    ``StationManager/stations``. Each row shows an antenna icon, the
///    station name, track count, and (when live) its stream URLs. The
///    context menu on a station row exposes broadcast toggle, URL copy,
///    rename, and delete. Task 3.5 expanded this from single-active-station
///    to a full list of persisted stations.
/// 2. **Library** — every playlist published by ``LibraryViewModel``.
///    Folder playlists with children render as `DisclosureGroup`s.
///
/// Library root order, guaranteed by the indexer:
/// 1. "All Songs" pinned to the top.
/// 2. "Loose Tracks" next, when the library root contains audio files
///    sitting outside any subfolder.
/// 3. Top-level folder playlists A–Z after that.
///
/// Selection is a ``SidebarSelection`` sum type bound from the parent so
/// the detail pane can branch on playlist-vs-station without the sidebar
/// having to care about detail rendering.
///
/// Right-clicking a playlist row offers "Create Station from this" — now
/// appends to the list instead of replacing the previous station.
public struct PlaylistsSidebarView: View {
    @ObservedObject public var vm: LibraryViewModel
    @ObservedObject public var stations: StationManager
    @ObservedObject public var radio: RadioBroadcaster
    /// Nested ObservableObject on `radio`. SwiftUI doesn't automatically
    /// observe children of an observed object, so we subscribe to the
    /// tunnel directly to get re-renders when `publicURL` / `mode` /
    /// `error` change mid-session.
    @ObservedObject public var tunnel: CloudflareTunnel
    /// Drives the "Downloads" section — surfaces in-flight and recently
    /// finished batches. Passed through from RootView so the sidebar and
    /// the add-download sheet share one instance.
    @ObservedObject public var downloadService: DownloadService
    @Binding public var selection: SidebarSelection?

    /// Local UI state for the rename dialog. Nil when no dialog is up.
    @State private var renameTarget: Station?
    @State private var renameText: String = ""
    /// Local UI state for the delete-confirmation alert. Nil when hidden.
    @State private var deleteTarget: Station?

    public init(
        vm: LibraryViewModel,
        stations: StationManager,
        radio: RadioBroadcaster,
        downloadService: DownloadService,
        selection: Binding<SidebarSelection?>
    ) {
        self.vm = vm
        self.stations = stations
        self.radio = radio
        self.tunnel = radio.tunnel
        self.downloadService = downloadService
        self._selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            if !stations.stations.isEmpty {
                Section("Stations") {
                    ForEach(stations.stations) { station in
                        stationRow(station)
                            .tag(SidebarSelection.station(station.id))
                            .contextMenu { stationContextMenu(station) }
                    }
                }
            }

            DownloadsSidebarSection(downloadService: downloadService)

            Section("Library") {
                ForEach(vm.playlists) { playlist in
                    node(playlist)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
        .alert(
            "Rename Station",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    stations.rename(target.id, to: renameText)
                }
                renameTarget = nil
            }
        }
        .alert(
            "Delete Station?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    // Stop any live broadcast first so we don't leave a
                    // dangling pipeline keyed by a now-deleted station.
                    if radio.isBroadcasting(stationID: target.id) {
                        radio.stopBroadcast(stationID: target.id)
                    }
                    stations.delete(target.id)
                }
                deleteTarget = nil
            }
        } message: {
            if let target = deleteTarget {
                Text("\"\(target.name)\" will be removed. This can't be undone.")
            }
        }
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
        let isLive = radio.isBroadcasting(stationID: station.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: station, isLive: isLive))
                    .foregroundStyle(isLive ? .red : .secondary)
                    .frame(width: 16)
                Text(station.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // NTS stations have an unbounded generative pool — showing
                // a track count there would be misleading (the queue is
                // always empty until a track resolves). Playlist stations
                // keep the familiar per-row count.
                if case .playlist = station.kind {
                    Text("\(station.queue.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            // Live current-track surface so the sidebar tells you what's
            // actually going out on the wire right now — without having to
            // open the Inspector or hover the toolbar antenna.
            if isLive, let item = radio.currentItemByStation[station.id] {
                HStack(spacing: 4) {
                    Image(systemName: "music.note")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(item.artist ?? "") — \(item.title ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 20)
            }
            // When broadcasting, surface this station's stream URL so the
            // user can aim VLC at it without digging through logs. Each
            // station has its own slug-based URL now; the tunnel URL is
            // shared across all live stations (one cloudflared per port).
            if isLive, let local = radio.streamURL(for: station) {
                Text("Local: \(local.absoluteString)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
                if let pub = publicURL(for: station) {
                    Text("Public: \(pub.absoluteString)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .padding(.leading, 24)
                } else if tunnel.mode == .starting {
                    Text("Public: starting tunnel…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 24)
                } else if let err = tunnel.error {
                    Text("Public: \(err)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .padding(.leading, 24)
                }
            }
        }
    }

    /// Right-click menu on any playlist row.
    @ViewBuilder
    private func playlistContextMenu(_ playlist: Playlist) -> some View {
        Button("Create Station from this") {
            let station = stations.create(from: playlist)
            selection = .station(station.id)
        }
    }

    /// Right-click menu on a station row. Mirrors the toolbar controls so
    /// a user can manage a station without first selecting it.
    @ViewBuilder
    private func stationContextMenu(_ station: Station) -> some View {
        let isLive = radio.isBroadcasting(stationID: station.id)
        Button(isLive ? "Stop Broadcast" : "Start Broadcast") {
            Task {
                if isLive {
                    radio.stopBroadcast(stationID: station.id)
                } else {
                    await radio.startBroadcast(station: station)
                }
            }
        }
        Button("Copy Stream URL") {
            let url = publicURL(for: station) ?? radio.streamURL(for: station)
            if let url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        .disabled(!isLive)
        Divider()
        Button("Rename…") {
            renameText = station.name
            renameTarget = station
        }
        Button("Delete", role: .destructive) {
            deleteTarget = station
        }
    }

    /// Compose the public per-station URL by splicing the station slug
    /// onto the tunnel base URL. Returns nil if the tunnel isn't up yet
    /// or if we couldn't parse its URL.
    private func publicURL(for station: Station) -> URL? {
        guard let base = tunnel.publicURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/stream/\(station.slug).aac"
        return components.url
    }

    private func iconName(for kind: Playlist.Kind, hasChildren: Bool) -> String {
        switch kind {
        case .allSongs:    return "music.note.list"
        case .looseTracks: return "music.note"
        case .folder:      return hasChildren ? "folder" : "music.note.list"
        }
    }

    /// Per-station icon. Playlist stations keep the antenna (matches the
    /// pre-refactor look); NTS stations get the waveform so the sidebar
    /// visually distinguishes "fixed queue" from "generative feed".
    private func iconName(for station: Station, isLive: Bool) -> String {
        switch station.kind {
        case .playlist:
            return isLive
                ? "antenna.radiowaves.left.and.right.circle.fill"
                : "antenna.radiowaves.left.and.right"
        case .nts:
            return isLive ? "waveform.circle.fill" : "waveform.circle"
        }
    }
}
#endif
