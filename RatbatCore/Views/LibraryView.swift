import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A column in the detail track list — both a sortable dimension and a
/// toggleable display surface.
///
/// The enum's declaration order is the UI ordering: the header row and
/// each ``TrackRow`` iterate `allCases` filtered by the user's visible
/// set, so adding a case (or moving one) is enough to change the column
/// layout. Kept `String`-backed + `Codable` so we can persist the visible
/// set as a JSON array inside `@AppStorage`.
public enum TrackColumn: String, CaseIterable, Hashable, Codable, Sendable {
    case trackNumber = "#"
    case title       = "Title"
    case artist      = "Artist"
    case album       = "Album"
    case year        = "Year"
    case genre       = "Genre"
    case duration    = "Duration"
    case bitrate     = "Bitrate"
    case fileSize    = "Size"
    case dateAdded   = "Added"

    /// Fixed column widths in points, `nil` for columns that should flex
    /// to fill available space. Header + row share this table so the two
    /// visually line up regardless of which columns are visible.
    static let widths: [TrackColumn: CGFloat?] = [
        .trackNumber: 40,
        .title:       nil,
        .artist:      180,
        .album:       180,
        .year:        60,
        .genre:       120,
        .duration:    80,
        .bitrate:     80,
        .fileSize:    90,
        .dateAdded:   120
    ]

    /// Which columns are shown on a freshly-installed app. Matches the
    /// pre-1.12 layout so existing users don't see the UI suddenly bloom.
    static let defaultVisible: Set<TrackColumn> = [.title, .artist, .album, .duration]

    /// Alignment for column content. `#` and numeric columns hug the
    /// trailing edge Spotify-style; everything else is leading.
    var alignment: Alignment {
        switch self {
        case .trackNumber, .duration, .bitrate, .fileSize: return .trailing
        default: return .leading
        }
    }

    /// Render the track's value for this column as a user-facing string.
    /// Empty-string for missing-optional cells so the layout stays stable.
    func render(_ track: Track) -> String {
        switch self {
        case .trackNumber: return track.trackNumber.map { "\($0)" } ?? ""
        case .title:       return track.title
        case .artist:      return track.artist
        case .album:       return track.album
        case .year:        return track.year.map { "\($0)" } ?? ""
        case .genre:       return track.genre ?? ""
        case .duration:    return TrackColumn.formatDuration(track.duration)
        case .bitrate:     return track.bitrate.map { "\($0) kbps" } ?? ""
        case .fileSize:    return TrackColumn.formatBytes(track.fileSize)
        case .dateAdded:
            return DateFormatter.localizedString(
                from: track.dateAdded,
                dateStyle: .short,
                timeStyle: .none
            )
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds > 0 else { return "–:–" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Detail view for a single ``Playlist``.
///
/// Two states:
/// - Empty: the playlist has no tracks (rare — e.g. a selected folder that
///   only contained non-audio files).
/// - List:  one row per track, sorted and filtered per the user's current
///   choice of sort column and search text.
///
/// ``LibraryView`` is now a pure "detail" view for a playlist picked in
/// ``PlaylistsSidebarView``. It no longer owns a ``LibraryViewModel`` —
/// that has moved up to ``RootView`` so the sidebar and detail share one
/// source of truth. Scanning is re-triggered by the parent via
/// `.task(id: folder)` on the split view itself.
///
/// Sort + filter state is intentionally local `@State` on ``LibraryView``
/// rather than lifted into the view model. Because the parent builds a
/// fresh ``LibraryView`` instance per selected playlist (see
/// ``PlaylistsSidebarView``/``RootView``), switching playlists naturally
/// resets search text, sort column, and selection — matching Spotify's
/// per-view fresh-start behaviour.
///
/// Interaction:
/// - Single-click (or arrow keys) selects a row via `List(selection:)`.
/// - Double-click or Enter plays the selected track.
/// - Right-click on a row opens a context menu with "Play" and "Show in
///   Finder". Right-click on a column header opens a menu toggling which
///   columns are visible — persisted across launches via `@AppStorage`.
/// - Clicking a column header sorts by that column; clicking the active
///   column again toggles ascending / descending.
/// - The toolbar search field (`.searchable`) filters by title, artist,
///   or album (case-insensitive substring).
///
/// The `onPlay` callback hands the *visible* (filtered + sorted) list plus
/// the starting index to the caller so the audio player queues exactly
/// what the user sees. Prev/next then traverses the filtered view, which
/// matches Spotify's "play from search results" behaviour.
public struct LibraryView: View {
    public let playlist: Playlist
    public let onPlay: ([Track], Int) -> Void

    /// The LibraryView owns the List selection locally (arrow keys,
    /// single-click highlight) but mirrors the picked track onto the
    /// view model so the Inspector pane and any other sibling UI can
    /// observe the same selection. See the `.onChange(of: selectedID)`
    /// below.
    @EnvironmentObject private var vm: LibraryViewModel

    @State private var selectedID: Track.ID?
    @State private var searchText: String = ""
    @State private var sortColumn: TrackColumn = .title
    @State private var sortAscending: Bool = true

    /// When a playlist is larger than ``initialPageSize`` tracks we only
    /// render the first page on launch — SwiftUI's `List` virtualization
    /// still struggles with many-thousand-row selection churn on sidebar
    /// toggle. The user can hit "Show all" to expand, or start typing in
    /// the search field (which always sees the full track list).
    @State private var showingAll: Bool = false
    private static let initialPageSize = 500

    /// Visible columns persisted as a JSON-encoded `[TrackColumn]` string.
    /// `@AppStorage` can't hold a `Set<TrackColumn>` directly, so we keep
    /// the raw string here and go through a computed `visibleColumns`
    /// accessor. The default matches the pre-1.12 layout.
    @AppStorage("ratbat.visibleColumns")
    private var visibleColumnsRaw: String = TrackColumn.defaultVisibleRaw

    private var visibleColumns: Set<TrackColumn> {
        guard let data = visibleColumnsRaw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([TrackColumn].self, from: data)
        else {
            return TrackColumn.defaultVisible
        }
        let decoded = Set(arr)
        return decoded.isEmpty ? TrackColumn.defaultVisible : decoded
    }

    public init(playlist: Playlist, onPlay: @escaping ([Track], Int) -> Void) {
        self.playlist = playlist
        self.onPlay = onPlay
    }

    /// Columns actually rendered in the UI, in enum declaration order,
    /// filtered by which ones the user has enabled.
    private var orderedVisibleColumns: [TrackColumn] {
        let visible = visibleColumns
        return TrackColumn.allCases.filter { visible.contains($0) }
    }

    /// The playlist's tracks after applying the current search filter and
    /// sort order. Computed on every render; playlist sizes for a personal
    /// music library (thousands, not millions) make this fine without
    /// memoisation.
    private var visibleTracks: [Track] {
        let filtered: [Track]
        if searchText.isEmpty {
            filtered = playlist.tracks
        } else {
            let needle = searchText.lowercased()
            filtered = playlist.tracks.filter { track in
                track.title.lowercased().contains(needle)
                    || track.artist.lowercased().contains(needle)
                    || track.album.lowercased().contains(needle)
            }
        }
        // Cap unfiltered view to initialPageSize for large playlists until
        // the user explicitly opts in — keeps sidebar toggle + split-pane
        // resize snappy on thousand-plus-track libraries.
        let capped: [Track]
        if searchText.isEmpty && !showingAll && filtered.count > Self.initialPageSize {
            capped = Array(filtered.prefix(Self.initialPageSize))
        } else {
            capped = filtered
        }
        let sorted = capped.sorted { lhs, rhs in
            switch sortColumn {
            case .trackNumber:
                return compareInt(lhs.trackNumber ?? .max, rhs.trackNumber ?? .max)
            case .title:    return compareStr(lhs.title, rhs.title)
            case .artist:   return compareStr(lhs.artist, rhs.artist)
            case .album:    return compareStr(lhs.album, rhs.album)
            case .year:
                return compareInt(lhs.year ?? .max, rhs.year ?? .max)
            case .genre:
                return compareStr(lhs.genre ?? "", rhs.genre ?? "")
            case .duration:
                return sortAscending ? lhs.duration < rhs.duration
                                     : lhs.duration > rhs.duration
            case .bitrate:
                return compareInt(lhs.bitrate ?? .max, rhs.bitrate ?? .max)
            case .fileSize:
                return sortAscending ? lhs.fileSize < rhs.fileSize
                                     : lhs.fileSize > rhs.fileSize
            case .dateAdded:
                return sortAscending ? lhs.dateAdded < rhs.dateAdded
                                     : lhs.dateAdded > rhs.dateAdded
            }
        }
        return sorted
    }

    /// Localised case-insensitive compare, honouring the current sort
    /// direction. Used for all string columns.
    private func compareStr(_ a: String, _ b: String) -> Bool {
        let order = a.localizedCaseInsensitiveCompare(b)
        if sortAscending { return order == .orderedAscending }
        else             { return order == .orderedDescending }
    }

    /// Integer compare honouring the current sort direction. Used for
    /// optional numeric columns (track number, year, bitrate) where
    /// callers substitute `.max` for `nil` so "unknown" rows sink to the
    /// bottom on ascending sort.
    private func compareInt(_ a: Int, _ b: Int) -> Bool {
        sortAscending ? a < b : a > b
    }

    public var body: some View {
        Group {
            if playlist.tracks.isEmpty {
                Text("No tracks in this playlist.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Column headers — clickable buttons that toggle sort.
                    // Right-click on any header opens the visibility menu.
                    HStack(spacing: 0) {
                        ForEach(orderedVisibleColumns, id: \.self) { column in
                            sortHeader(column)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .contextMenu { columnVisibilityMenu }

                    Divider()

                    List(selection: $selectedID) {
                        ForEach(visibleTracks) { track in
                            TrackRow(track: track, columns: orderedVisibleColumns)
                                .contentShape(Rectangle())
                                // `simultaneousGesture` — not `.onTapGesture` —
                                // so the List's own single-click selection
                                // handler still fires. A plain onTapGesture
                                // here swallows some clicks depending on
                                // where in the row you hit, leaving rows
                                // that look selected-but-aren't.
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded { play(track) }
                                )
                                .contextMenu {
                                    Button("Play") { play(track) }
                                    Button("Show in Finder") { showInFinder(track) }
                                    Divider()
                                    Button("Get Info") {
                                        // Surfaces the Inspector pane on
                                        // macOS. On iOS the VM property is
                                        // still there but harmlessly unused
                                        // (LibraryView also isn't used
                                        // there today).
                                        selectedID = track.id
                                        vm.selectedTrack = track
                                        vm.isInspectorOpen = true
                                    }
                                }
                                .tag(track.id)
                        }
                    }
                    .onKeyPress(.return) {
                        if let id = selectedID,
                           let track = visibleTracks.first(where: { $0.id == id }) {
                            play(track)
                            return .handled
                        }
                        return .ignored
                    }

                    if visibleTracks.isEmpty && !searchText.isEmpty {
                        Text("No tracks match \u{201C}\(searchText)\u{201D}")
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity)
                    }

                    // "Show all" escape hatch when we capped a large playlist.
                    // Searching or sorting still sees the whole set — the cap
                    // only applies to the unfiltered default view.
                    if !showingAll
                        && searchText.isEmpty
                        && playlist.tracks.count > Self.initialPageSize {
                        HStack(spacing: 6) {
                            Text("Showing first \(Self.initialPageSize) of \(playlist.tracks.count) tracks.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Show all") { showingAll = true }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.thinMaterial)
                    }
                }
            }
        }
        .navigationTitle(playlist.name)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter tracks")
        // Mirror row selection onto the view model so sibling UI — the
        // macOS Inspector pane, or any future panel keyed on the current
        // track — observes the same pick. We check both the visible
        // (filtered + sorted) list and the full playlist so selection made
        // via arrow keys or the context menu always resolves.
        .onChange(of: selectedID) { _, newID in
            guard let id = newID else {
                vm.selectedTrack = nil
                return
            }
            vm.selectedTrack = visibleTracks.first(where: { $0.id == id })
                ?? playlist.tracks.first(where: { $0.id == id })
        }
    }

    /// Builds a single clickable header cell. Widths come from
    /// ``TrackColumn/widths`` so the header and row stay in sync as
    /// columns are toggled in and out.
    @ViewBuilder
    private func sortHeader(_ column: TrackColumn) -> some View {
        let width = TrackColumn.widths[column] ?? nil
        let alignment = column.alignment
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 4) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(column.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(
                maxWidth: width == nil ? .infinity : width,
                alignment: alignment
            )
        }
        .buttonStyle(.plain)
        .contextMenu { columnVisibilityMenu }
    }

    /// Menu offering a toggle per column. A `checkmark` icon marks the
    /// currently-visible ones. We refuse to remove the final column so
    /// the UI can never wedge into a zero-column state.
    @ViewBuilder
    private var columnVisibilityMenu: some View {
        ForEach(TrackColumn.allCases, id: \.self) { col in
            Button {
                toggleColumn(col)
            } label: {
                Label(
                    col.rawValue,
                    systemImage: visibleColumns.contains(col) ? "checkmark" : ""
                )
            }
        }
    }

    /// Add or remove a column from the visible set, then persist. Refuses
    /// to remove the last remaining column — the user always sees at
    /// least one.
    private func toggleColumn(_ col: TrackColumn) {
        var set = visibleColumns
        if set.contains(col) {
            guard set.count > 1 else { return }
            set.remove(col)
            // If we just hid the current sort column, fall back to the
            // first still-visible column so sorting stays meaningful.
            if sortColumn == col,
               let fallback = TrackColumn.allCases.first(where: { set.contains($0) }) {
                sortColumn = fallback
            }
        } else {
            set.insert(col)
        }
        persistVisible(set)
    }

    private func persistVisible(_ set: Set<TrackColumn>) {
        // Encode in enum order for a stable, readable JSON string.
        let arr = TrackColumn.allCases.filter { set.contains($0) }
        if let data = try? JSONEncoder().encode(arr),
           let str = String(data: data, encoding: .utf8) {
            visibleColumnsRaw = str
        }
    }

    private func play(_ track: Track) {
        // Use the visible (filtered + sorted) list as the queue so that
        // prev/next traverses exactly what the user sees — matches
        // Spotify's play-from-search behaviour.
        guard let index = visibleTracks.firstIndex(where: { $0.id == track.id }) else { return }
        onPlay(visibleTracks, index)
    }

    private func showInFinder(_ track: Track) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
        #endif
    }
}

extension TrackColumn {
    /// Default `@AppStorage` string — the JSON encoding of
    /// ``TrackColumn/defaultVisible``. Computed once at file scope so the
    /// property wrapper's default parameter stays a constant expression.
    static let defaultVisibleRaw: String = {
        let arr = TrackColumn.allCases.filter { defaultVisible.contains($0) }
        guard let data = try? JSONEncoder().encode(arr),
              let str = String(data: data, encoding: .utf8) else {
            return "[\"Title\",\"Artist\",\"Album\",\"Duration\"]"
        }
        return str
    }()
}

/// One row in the detail list. Renders whatever columns the parent has
/// decided are visible, in the parent's supplied order. Widths come from
/// ``TrackColumn/widths`` so we never drift out of alignment with the
/// header row.
struct TrackRow: View {
    let track: Track
    let columns: [TrackColumn]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                cell(for: column)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func cell(for column: TrackColumn) -> some View {
        let width = TrackColumn.widths[column] ?? nil
        let alignment = column.alignment
        let text = column.render(track)
        let isPrimary = column == .title

        Text(text.isEmpty ? " " : text)
            .font(isPrimary ? .body : fontForNumeric(column))
            .foregroundStyle(isPrimary ? .primary : .secondary)
            .lineLimit(1)
            .frame(
                maxWidth: width == nil ? .infinity : width,
                alignment: alignment
            )
    }

    /// Monospace-digit caption for numeric columns so they line up
    /// vertically; plain caption for everything else.
    private func fontForNumeric(_ column: TrackColumn) -> Font {
        switch column {
        case .trackNumber, .duration, .bitrate, .fileSize, .year:
            return .caption.monospacedDigit()
        default:
            return .caption
        }
    }
}
