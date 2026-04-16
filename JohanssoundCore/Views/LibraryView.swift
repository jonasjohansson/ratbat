import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Detail view for a single ``Playlist``.
///
/// Two states:
/// - Empty: the playlist has no tracks (rare — e.g. a selected folder that
///   only contained non-audio files).
/// - List:  one row per track, in the order the indexer produced them.
///
/// ``LibraryView`` is now a pure "detail" view for a playlist picked in
/// ``PlaylistsSidebarView``. It no longer owns a ``LibraryViewModel`` —
/// that has moved up to ``RootView`` so the sidebar and detail share one
/// source of truth. Scanning is re-triggered by the parent via
/// `.task(id: folder)` on the split view itself.
///
/// Interaction:
/// - Single-click (or arrow keys) selects a row via `List(selection:)`.
/// - Double-click or Enter plays the selected track.
/// - Right-click opens a context menu with "Play" and "Show in Finder".
///
/// The `onPlay` callback hands the *whole* playlist plus the starting
/// index to the caller so the audio player can queue the full playlist and
/// have next/prev traverse it, rather than playing a one-track queue.
public struct LibraryView: View {
    public let playlist: Playlist
    public let onPlay: ([Track], Int) -> Void
    @State private var selectedID: Track.ID?

    public init(playlist: Playlist, onPlay: @escaping ([Track], Int) -> Void) {
        self.playlist = playlist
        self.onPlay = onPlay
    }

    public var body: some View {
        Group {
            if playlist.tracks.isEmpty {
                Text("No tracks in this playlist.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(playlist.tracks) { track in
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
                       let track = playlist.tracks.first(where: { $0.id == id }) {
                        play(track)
                        return .handled
                    }
                    return .ignored
                }
            }
        }
        .navigationTitle(playlist.name)
    }

    private func play(_ track: Track) {
        guard let index = playlist.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        onPlay(playlist.tracks, index)
    }

    private func showInFinder(_ track: Track) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
        #endif
    }
}

struct TrackRow: View {
    let track: Track

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formatDuration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds > 0 else { return "–:–" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
