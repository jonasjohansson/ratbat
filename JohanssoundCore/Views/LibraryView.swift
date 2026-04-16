import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Which column the detail list is currently sorted by. Kept as a raw-value
/// `String` enum so the header label can be pulled straight from the case.
public enum TrackSortColumn: String, CaseIterable, Hashable {
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case duration = "Duration"
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
/// - Right-click opens a context menu with "Play" and "Show in Finder".
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

    @State private var selectedID: Track.ID?
    @State private var searchText: String = ""
    @State private var sortColumn: TrackSortColumn = .title
    @State private var sortAscending: Bool = true

    public init(playlist: Playlist, onPlay: @escaping ([Track], Int) -> Void) {
        self.playlist = playlist
        self.onPlay = onPlay
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
        let sorted = filtered.sorted { lhs, rhs in
            switch sortColumn {
            case .title:    return compareStr(lhs.title, rhs.title)
            case .artist:   return compareStr(lhs.artist, rhs.artist)
            case .album:    return compareStr(lhs.album, rhs.album)
            case .duration:
                return sortAscending ? lhs.duration < rhs.duration
                                     : lhs.duration > rhs.duration
            }
        }
        return sorted
    }

    /// Localised case-insensitive compare, honouring the current sort
    /// direction. Used for all three string columns.
    private func compareStr(_ a: String, _ b: String) -> Bool {
        let order = a.localizedCaseInsensitiveCompare(b)
        if sortAscending { return order == .orderedAscending }
        else             { return order == .orderedDescending }
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
                    HStack(spacing: 0) {
                        sortHeader(.title,    width: nil, alignment: .leading)
                        sortHeader(.artist,   width: 180, alignment: .leading)
                        sortHeader(.album,    width: 180, alignment: .leading)
                        sortHeader(.duration, width: 80,  alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)

                    Divider()

                    List(selection: $selectedID) {
                        ForEach(visibleTracks) { track in
                            TrackRow(track: track)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { play(track) }
                                .contextMenu {
                                    Button("Play") { play(track) }
                                    Button("Show in Finder") { showInFinder(track) }
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
                }
            }
        }
        .navigationTitle(playlist.name)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter tracks")
    }

    /// Builds a single clickable header cell. Widths here must match the
    /// widths in ``TrackRow`` so columns visually line up.
    @ViewBuilder
    private func sortHeader(
        _ column: TrackSortColumn,
        width: CGFloat?,
        alignment: Alignment
    ) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(column.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(
                maxWidth: width == nil ? .infinity : width,
                alignment: alignment
            )
        }
        .buttonStyle(.plain)
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

/// One row in the detail list. Laid out as four columns whose widths match
/// the header widths above so the table visually aligns.
struct TrackRow: View {
    let track: Track

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            Text(track.album)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            Text(formatDuration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds > 0 else { return "–:–" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
