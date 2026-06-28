import SwiftUI

/// Bottom-bar player UI for the Mac app.
///
/// Observes an `AudioPlayer` passed in from ``RootView`` via
/// `@ObservedObject` (not `@StateObject`) because the player is owned by
/// the parent and must persist across library reloads.
///
/// Layout: track info on the left, transport controls in the middle, and
/// a seek slider with elapsed/total time on the right. All controls are
/// disabled when no track is loaded.
public struct PlayerView: View {
    @ObservedObject public var player: AudioPlayer

    public init(player: AudioPlayer) {
        self.player = player
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let error = player.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.12))
            }
            HStack(spacing: 16) {
                trackInfo
                Spacer(minLength: 20)
                transportControls
                progressControls
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder private var trackInfo: some View {
        if let track = player.currentTrack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.callout).lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)
        } else {
            Text("No track")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 180, alignment: .leading)
        }
    }

    @ViewBuilder private var transportControls: some View {
        HStack(spacing: 20) {
            Button(action: { player.previous() }) {
                Image(systemName: "backward.fill")
            }
            .disabled(player.currentTrack == nil)

            Button(action: { player.togglePlayPause() }) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .disabled(player.currentTrack == nil)
            .keyboardShortcut(.space, modifiers: [])

            Button(action: { player.next() }) {
                Image(systemName: "forward.fill")
            }
            .disabled(player.currentTrack == nil)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var progressControls: some View {
        // Guard the slider's range against NaN / 0 durations: if the track
        // duration isn't a sensible positive number, fall back to 1 so
        // SwiftUI's Slider doesn't crash on an invalid range.
        let rawDuration = player.currentTrack?.duration ?? 0
        let duration: TimeInterval = (rawDuration.isFinite && rawDuration > 0) ? rawDuration : 1
        let clampedProgress = min(max(player.progress, 0), duration)

        HStack(spacing: 8) {
            Text(formatTime(player.progress))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { clampedProgress },
                    set: { player.seek(to: $0) }
                ),
                in: 0...duration
            )
            .disabled(player.currentTrack == nil)

            Text(formatTime(player.currentTrack?.duration ?? 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
        .frame(minWidth: 300)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
