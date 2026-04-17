#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation

/// Right-side Inspector pane modelled on Finder / Music.app's "Get Info"
/// panel. Renders the full metadata and file facts we already carry on
/// ``Track`` plus any embedded cover artwork we can load off the file.
///
/// Presented via ``RootView``'s `.inspector(isPresented:)` modifier, which
/// slides in a third column to the right of the detail pane. The track it
/// displays is pulled from ``LibraryViewModel/selectedTrack`` so row
/// selection in ``LibraryView`` drives the pane without the two views
/// needing to know about each other.
///
/// The Inspector is deliberately macOS-only (`#if os(macOS)`) because the
/// `.inspector` modifier itself requires macOS 14 and the rest of the Mac
/// app's chrome (column layout, toolbar). iOS gets a different surface.
///
/// Artwork is best-effort: we walk `AVURLAsset.commonMetadata` off the main
/// actor, grab the first `commonKeyArtwork` item, and decode it into an
/// `NSImage`. Failures are swallowed — many files have no embedded art and
/// we don't want the pane to flash an error for the common case.
public struct TrackInspectorView: View {
    public let track: Track?
    public let onPlay: (Track) -> Void

    @State private var artworkImage: NSImage?

    public init(track: Track?, onPlay: @escaping (Track) -> Void) {
        self.track = track
        self.onPlay = onPlay
    }

    public var body: some View {
        ScrollView {
            if let track {
                content(for: track)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .task(id: track?.id) { await loadArtwork(for: track) }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a track to see its info")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for track: Track) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            artworkBlock
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(3)
                Text(track.artist).foregroundStyle(.secondary)
                Text(track.album)
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            }
            Divider()
            metadataGrid(for: track)
            Divider()
            actions(for: track)
        }
        .padding(20)
    }

    @ViewBuilder
    private var artworkBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .separatorColor).opacity(0.3))
            if let artworkImage {
                Image(nsImage: artworkImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 60))
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func metadataGrid(for track: Track) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Duration", formatDuration(track.duration))
            if let tn = track.trackNumber { row("Track", "\(tn)") }
            if let year = track.year { row("Year", "\(year)") }
            if let genre = track.genre, !genre.isEmpty { row("Genre", genre) }
            if let kbps = track.bitrate { row("Bitrate", "\(kbps) kbps") }
            if track.fileSize > 0 {
                row(
                    "Size",
                    ByteCountFormatter.string(
                        fromByteCount: track.fileSize,
                        countStyle: .file
                    )
                )
            }
            row("Added", track.dateAdded.formatted(date: .abbreviated, time: .omitted))
            row("Format", track.url.pathExtension.uppercased())
            GridRow {
                Text("Path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(track.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func actions(for track: Track) -> some View {
        HStack(spacing: 8) {
            Button {
                onPlay(track)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([track.url])
            } label: {
                Label("Finder", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(track.url.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.clipboard")
            }
        }
        .controlSize(.small)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds > 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Best-effort artwork load. Walks `commonMetadata`, grabs the first
    /// `commonKeyArtwork` item's data, and decodes it. Anything going wrong
    /// — non-image data, a format `NSImage` can't parse, or a missing
    /// artwork tag — just leaves `artworkImage` nil and the placeholder
    /// note glyph renders instead.
    private func loadArtwork(for track: Track?) async {
        guard let track else {
            artworkImage = nil
            return
        }
        let asset = AVURLAsset(url: track.url)
        do {
            let items = try await asset.load(.commonMetadata)
            for item in items where item.commonKey == .commonKeyArtwork {
                if let data = try await item.load(.dataValue),
                   let img = NSImage(data: data) {
                    artworkImage = img
                    return
                }
            }
        } catch {
            // Artwork is best-effort — fall through to the placeholder.
        }
        artworkImage = nil
    }
}
#endif
