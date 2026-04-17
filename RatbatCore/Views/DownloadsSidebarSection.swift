#if os(macOS)
import SwiftUI

/// Sidebar section that surfaces in-flight and recently-finished download
/// batches from ``DownloadService``. Renders nothing when there are no
/// batches, so it stays invisible until the user triggers a download.
///
/// Each row shows:
/// 1. The destination folder name (so multi-folder downloads are
///    distinguishable at a glance).
/// 2. A status subtitle: "N of M" while active, "Done · N tracks" on
///    completion, or the error message if the batch failed.
/// 3. The currently matching/downloading track as a small progress line
///    underneath the main row — the most useful signal during a long
///    playlist pull.
/// 4. A cancel button (×) while the batch is active.
public struct DownloadsSidebarSection: View {
    @ObservedObject public var downloadService: DownloadService

    public init(downloadService: DownloadService) {
        self.downloadService = downloadService
    }

    public var body: some View {
        if !downloadService.batches.isEmpty {
            Section("Downloads") {
                ForEach(downloadService.batches) { batch in
                    DownloadsBatchRow(batch: batch) {
                        downloadService.cancel(batchID: batch.id)
                    }
                }
            }
        }
    }
}

/// One row per batch. Pulled out of the section so the `@ObservedObject`
/// wrapper on the service doesn't have to re-render the full `ForEach`
/// body for every field access.
private struct DownloadsBatchRow: View {
    let batch: DownloadService.Batch
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(batch.destination.lastPathComponent)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if batch.isActive {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }
            }

            // Active job indicator — show the track currently matching or
            // downloading. We take the LAST such job because the parser
            // flips the previous in-flight entry to `.done` when a new
            // `[MATCHING]` arrives, but there's always at most one truly
            // live track at any instant.
            if let active = batch.jobs.last(where: { $0.status == .matching || $0.status == .downloading }) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(active.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if batch.isActive { return "arrow.down.circle" }
        if batch.errorMessage != nil { return "exclamationmark.circle" }
        return "checkmark.circle.fill"
    }

    private var iconColor: Color {
        if batch.isActive { return .secondary }
        if batch.errorMessage != nil { return .orange }
        return .green
    }

    private var subtitle: String {
        if let err = batch.errorMessage {
            return err
        }
        if batch.isActive {
            let total = batch.jobs.count
            return total > 0 ? "\(batch.completedCount) of \(total)" : "Starting…"
        }
        return "Done · \(batch.completedCount) tracks"
    }
}
#endif
