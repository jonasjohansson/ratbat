import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shows the tracks found in a given music folder.
///
/// Four states:
/// - Loading: progress indicator while the indexer scans.
/// - Error:   a short message with the underlying localised description.
/// - Empty:   the folder exists but contains no audio files.
/// - List:    one row per track, sorted by the indexer.
///
/// The scan is re-triggered when `folder` changes, via `.task(id: folder)`,
/// so swapping folders in a parent view will refresh the list without
/// rebuilding ``LibraryView``.
///
/// Interaction:
/// - Single-click (or arrow keys) selects a row via `List(selection:)`.
/// - Double-click or Enter plays the selected track.
/// - Right-click opens a context menu with "Play" and "Show in Finder".
///
/// The `onPlay` callback hands the *whole* track list plus the starting
/// index to the caller so the audio player can queue the full library and
/// have next/prev traverse it, rather than playing a one-track queue.
public struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    @State private var selectedID: Track.ID?
    public let folder: URL
    public let onPlay: ([Track], Int) -> Void

    public init(folder: URL, onPlay: @escaping ([Track], Int) -> Void) {
        self.folder = folder
        self.onPlay = onPlay
    }

    public var body: some View {
        Group {
            if vm.isLoading {
                ProgressView("Scanning library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.error {
                VStack(spacing: 12) {
                    Text("Couldn't read library").font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.tracks.isEmpty {
                Text("No audio files in this folder.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(vm.tracks) { track in
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
                       let track = vm.tracks.first(where: { $0.id == id }) {
                        play(track)
                        return .handled
                    }
                    return .ignored
                }
            }
        }
        .task(id: folder) { await vm.load(from: folder) }
    }

    private func play(_ track: Track) {
        guard let index = vm.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        onPlay(vm.tracks, index)
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
