#if os(macOS)
import SwiftUI

/// Top-level macOS view that decides between onboarding (folder picker) and
/// the library proper, based on whether ``LibraryConfig`` has a stored
/// music folder.
///
/// Spotify-style layout, wired in Task 1.9 and extended in Task 3.1 with a
/// "Stations" section in the sidebar. Task 3.5 generalised stations from
/// "one active at a time" to a full persisted list with multi-broadcast
/// support; the toolbar antenna now operates on the currently-selected
/// station.
///
/// - Sidebar: ``PlaylistsSidebarView`` showing every saved station plus
///   every library playlist.
/// - Detail:  ``LibraryView`` of the currently selected playlist *or*
///   station — the sidebar selection is a ``SidebarSelection`` sum type
///   and the detail pane branches on the case.
/// - Bottom:  ``PlayerView`` bar that spans the whole window — deliberately
///   outside the split so it stays put as the user swaps sidebar/detail.
///
/// Owns the shared ``AudioPlayer``, ``LibraryViewModel``, ``StationManager``,
/// and ``RadioBroadcaster`` for the window. All four are `@StateObject` so
/// they survive library reloads and folder changes. When the user picks a
/// folder we point the station manager at it so its
/// `.ratbat-stations.json` can round-trip.
///
/// iOS uses a different entry point (no folder picker, no bottom player
/// bar, no split view), so this view is macOS-only.
public struct RootView: View {
    @State private var musicFolder: URL?
    @StateObject private var player = AudioPlayer()
    @StateObject private var libraryVM = LibraryViewModel()
    @StateObject private var stations = StationManager()
    @StateObject private var preferences = BroadcastPreferences.shared
    @StateObject private var downloadService: DownloadService
    @StateObject private var radio: RadioBroadcaster
    /// Shared taste profile — owned by the view for window lifetime. Not
    /// an `ObservableObject` (scoring reads don't drive SwiftUI updates),
    /// just a reference we pass into the broadcaster so Last.fm
    /// controllers can consult it for pool scoring.
    private let tasteProfile: TasteProfile
    @State private var sidebarSelection: SidebarSelection?
    @State private var showingAddDownload: Bool = false
    @State private var showingAddNTSStation: Bool = false
    @State private var showingAddLastFMStation: Bool = false
    @State private var showingAddBandcampStation: Bool = false
    /// Owned by the view so it lives as long as the window does. Held as
    /// optional `@State` because we can't `@StateObject` a non-
    /// `ObservableObject`, and we want to construct it *after* `player`
    /// is guaranteed to exist (first `onAppear`).
    @State private var nowPlaying: NowPlayingController?
    private let config: LibraryConfig

    public init(config: LibraryConfig = LibraryConfig()) {
        self.config = config
        self._musicFolder = State(initialValue: config.musicFolder)

        // Wire up the broadcaster with the NTS stack dependencies so
        // NTS-backed stations can actually resolve + cache tracks. The
        // download service is shared between the broadcaster and the
        // sidebar's Downloads section — one venv, one state publisher.
        let ds = DownloadService()
        // Construct the taste profile once per window — it'll be
        // ingested with library tracks after the first library load,
        // and the scoring actor outlives individual broadcasts so ♥
        // and 👎 signals accumulate across the session.
        let profile = TasteProfile()
        let broadcaster = RadioBroadcaster(
            preferences: .shared,
            downloadService: ds,
            nts: NTSClient(),
            history: try? HistoryStore(),
            libraryConfig: config,
            tasteProfile: profile
        )
        self._downloadService = StateObject(wrappedValue: ds)
        self._radio = StateObject(wrappedValue: broadcaster)
        self.tasteProfile = profile
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                if let folder = musicFolder {
                    NavigationSplitView {
                        PlaylistsSidebarView(
                            vm: libraryVM,
                            stations: stations,
                            radio: radio,
                            downloadService: downloadService,
                            selection: $sidebarSelection
                        )
                        .frame(minWidth: 180)
                    } detail: {
                        detailView
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            addDownloadButton
                        }
                        ToolbarItem(placement: .primaryAction) {
                            newStationMenu
                        }
                        ToolbarItem(placement: .primaryAction) {
                            qualityMenu
                        }
                        ToolbarItem(placement: .primaryAction) {
                            broadcastButton
                        }
                    }
                    .sheet(isPresented: $showingAddDownload) {
                        if let folder = musicFolder {
                            AddDownloadView(
                                downloadService: downloadService,
                                libraryFolder: folder
                            )
                        }
                    }
                    .sheet(isPresented: $showingAddNTSStation) {
                        AddNTSStationView(stations: stations)
                    }
                    .sheet(isPresented: $showingAddLastFMStation) {
                        AddLastFMStationView(stations: stations, preferences: preferences)
                    }
                    .sheet(isPresented: $showingAddBandcampStation) {
                        AddBandcampStationView(stations: stations)
                    }
                    .task(id: folder) {
                        // Point the station manager at the new folder
                        // BEFORE loading the library so any saved stations
                        // are visible in the sidebar as soon as it appears.
                        stations.setStorage(root: folder)
                        await libraryVM.load(from: folder)
                        // Feed the taste profile with the freshly-loaded
                        // tracks so Last.fm pool scoring has something to
                        // work with. Runs after the library load so an
                        // "All Songs" playlist exists to draw from.
                        let allTracks = libraryVM.playlists.flatMap { $0.tracks }
                        await tasteProfile.ingestLibrary(allTracks)
                        // Persist the snapshot so future launches can prime
                        // the profile synchronously and scoring is live
                        // before the library re-scan finishes.
                        if let snapshotURL = try? TasteProfileStore.defaultURL() {
                            let snapshot = await tasteProfile.currentSnapshot()
                            try? TasteProfileStore.save(snapshot, to: snapshotURL)
                        }
                    }
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
                    // Re-scan the library whenever any batch's `finishedAt`
                    // changes — that fires both when a batch completes
                    // (nil → Date) and when a new one is appended (its
                    // `finishedAt` is nil, which still changes the array).
                    // Re-scanning an already-scanned folder is cheap and
                    // cache-backed, so we don't need a more precise trigger.
                    .onChange(of: downloadService.batches.map(\.finishedAt)) { _, _ in
                        guard let folder = musicFolder else { return }
                        Task { await libraryVM.load(from: folder) }
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
                if radio.needsRestart {
                    // Surfaces here rather than in the Settings pane because
                    // the user may have Settings closed when they change
                    // something — the main window is always visible.
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundStyle(.orange)
                        Text("Broadcast settings changed — restart broadcast to apply.")
                            .font(.caption)
                        Spacer()
                        Button("Restart All") {
                            let liveStations = stations.stations.filter {
                                radio.isBroadcasting(stationID: $0.id)
                            }
                            radio.stopAll()
                            Task {
                                for station in liveStations {
                                    await radio.startBroadcast(station: station)
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.12))
                }
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

    /// Toolbar button that opens the "Download from Spotify" sheet. Disabled
    /// until a library folder is selected — downloads need a root to land in.
    /// ⇧⌘D matches the "add to library" feel used by other media apps.
    @ViewBuilder private var addDownloadButton: some View {
        Button {
            showingAddDownload = true
        } label: {
            Image(systemName: "plus.circle")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .help("Download from Spotify (⇧⌘D)")
        .disabled(musicFolder == nil)
    }

    /// Toolbar menu for creating new stations. Playlist stations are
    /// created via the sidebar's right-click "Create Station from this"
    /// on any playlist row; this menu covers the generative kinds
    /// (NTS / Last.fm / Bandcamp) which need a config sheet.
    @ViewBuilder private var newStationMenu: some View {
        Menu {
            Button("New NTS Station…") {
                showingAddNTSStation = true
            }
            Button("New Last.fm Station…") {
                showingAddLastFMStation = true
            }
            Button("New Bandcamp Station…") {
                showingAddBandcampStation = true
            }
        } label: {
            Image(systemName: "plus.circle.dashed")
        }
        .help("Create a new station")
    }

    /// Toolbar Picker surfacing the broadcast quality in the main window
    /// so users don't need to dig into Preferences (⌘,) to switch bitrate.
    /// Changes still only take effect at next broadcast start — the
    /// `needsRestart` banner handles that messaging.
    @ViewBuilder private var qualityMenu: some View {
        Picker("Quality", selection: $preferences.quality) {
            ForEach(AudioQuality.allCases, id: \.self) { quality in
                Text(quality.label).tag(quality)
            }
        }
        .pickerStyle(.menu)
        .help("Broadcast quality · Set in Preferences (⌘,) for more options")
    }

    /// Toolbar button that broadcasts the currently-selected station.
    /// Task 3.5: the toolbar is now context-sensitive to the sidebar
    /// selection — pick a station, click the antenna, it goes live (or
    /// stops if already live). Selecting a playlist disables the button
    /// with a hint to create a station first.
    @ViewBuilder private var broadcastButton: some View {
        let target = selectedStation
        let isLive = target.map { radio.isBroadcasting(stationID: $0.id) } ?? false
        Button {
            guard let station = target else { return }
            Task {
                if isLive {
                    radio.stopBroadcast(stationID: station.id)
                } else {
                    await radio.startBroadcast(station: station)
                }
            }
        } label: {
            Image(systemName: isLive
                ? "antenna.radiowaves.left.and.right.circle.fill"
                : "antenna.radiowaves.left.and.right")
        }
        .disabled(target == nil)
        .help(broadcastHelpText)
    }

    /// Returns the station the toolbar should act on — the sidebar
    /// selection when it's a station, nil otherwise.
    private var selectedStation: Station? {
        guard case let .some(.station(id)) = sidebarSelection else { return nil }
        return stations.stations.first(where: { $0.id == id })
    }

    private var broadcastHelpText: String {
        guard let station = selectedStation else {
            if stations.stations.isEmpty {
                return "Create a station first (right-click a playlist)"
            }
            return "Select a station to broadcast it"
        }
        if radio.isBroadcasting(stationID: station.id) {
            let url = radio.streamURL(for: station)?.absoluteString ?? "?"
            var parts = ["Broadcasting at \(url)"]
            if let item = radio.currentItemByStation[station.id] {
                parts.append("Now: \(item.artist ?? "") — \(item.title ?? "")")
            }
            parts.append("Click to stop.")
            return parts.joined(separator: " · ")
        } else {
            return "Broadcast \(station.name)"
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
        } else if let ntsStation = resolvedNTSStation {
            // NTS stations have no fixed queue — render their dedicated
            // detail pane (config + status + now playing) instead of the
            // track-list LibraryView.
            NTSStationDetailView(
                station: ntsStation.0,
                config: ntsStation.1,
                radio: radio,
                onBroadcastToggle: {
                    Task {
                        if radio.isBroadcasting(stationID: ntsStation.0.id) {
                            radio.stopBroadcast(stationID: ntsStation.0.id)
                        } else {
                            await radio.startBroadcast(station: ntsStation.0)
                        }
                    }
                }
            )
        } else if let lastFMStation = resolvedLastFMStation {
            LastFMStationDetailView(
                station: lastFMStation.0,
                config: lastFMStation.1,
                radio: radio,
                onBroadcastToggle: {
                    Task {
                        if radio.isBroadcasting(stationID: lastFMStation.0.id) {
                            radio.stopBroadcast(stationID: lastFMStation.0.id)
                        } else {
                            await radio.startBroadcast(station: lastFMStation.0)
                        }
                    }
                }
            )
        } else if let playlist = resolvedDetailPlaylist {
            LibraryView(playlist: playlist) { tracks, startIndex in
                // Queue the whole playlist and start from the picked
                // track so prev/next (and media keys) traverse the
                // full list rather than bouncing on a one-track queue.
                player.play(queue: tracks, startingAt: startIndex)
            }
            // LibraryView reads the shared view model off the environment
            // to mirror its row selection onto `selectedTrack` and to
            // raise the Inspector from its context menu. We always inject
            // the same VM instance the rest of RootView already drives.
            .environmentObject(libraryVM)
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
    /// When the sidebar selection resolves to an NTS-backed station,
    /// return it + its config so the detail pane can render its
    /// dedicated view. Returns nil for playlist selections or when the
    /// selected station is a playlist-backed one.
    private var resolvedNTSStation: (Station, NTSStationConfig)? {
        guard case let .some(.station(id)) = sidebarSelection,
              let station = stations.stations.first(where: { $0.id == id }),
              let config = station.ntsConfig
        else { return nil }
        return (station, config)
    }

    /// When the sidebar selection resolves to a Last.fm-backed station,
    /// return it + its config so the detail pane can render its dedicated
    /// view. Mirrors ``resolvedNTSStation`` for the other generative kind.
    private var resolvedLastFMStation: (Station, LastFMStationConfig)? {
        guard case let .some(.station(id)) = sidebarSelection,
              let station = stations.stations.first(where: { $0.id == id }),
              let config = station.lastFMConfig
        else { return nil }
        return (station, config)
    }

    private var resolvedDetailPlaylist: Playlist? {
        switch sidebarSelection {
        case .some(.station(let id)):
            if let station = stations.stations.first(where: { $0.id == id }) {
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
