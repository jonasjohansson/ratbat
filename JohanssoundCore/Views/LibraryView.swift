import SwiftUI

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
public struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
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
                List(vm.tracks) { track in
                    TrackRow(track: track)
                }
            }
        }
        .task(id: folder) { await vm.load(from: folder) }
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
