#if os(macOS)
import SwiftUI

/// Detail pane for a Library Radio station. Mirrors
/// ``LastFMStationDetailView`` minimally — config summary + broadcast
/// state + now-playing — because this kind, too, has no fixed queue to
/// list: the pool re-derives from the live library and taste signals at
/// every refill, so the honest thing to show is the filter and what is
/// on air, not a snapshot pretending to be a tracklist.
///
/// No ♥ button here, deliberately: every track this station plays is
/// already in the library, so "Save to Library" would be a button that
/// can only say "you already have this". Skip (👎) stays — teaching the
/// station what to avoid is half the point of the kind.
public struct LibraryRadioStationDetailView: View {
    public let station: Station
    public let config: LibraryRadioStationConfig
    @ObservedObject public var radio: RadioBroadcaster
    public let onBroadcastToggle: () -> Void
    /// Raised when the user asks to change the station's filters — the
    /// sheet lives in ``RootView``, same shape as the sibling panes.
    public let onEdit: () -> Void

    @State private var skippedByURL: [URL: Bool] = [:]

    public init(
        station: Station,
        config: LibraryRadioStationConfig,
        radio: RadioBroadcaster,
        onBroadcastToggle: @escaping () -> Void,
        onEdit: @escaping () -> Void
    ) {
        self.station = station
        self.config = config
        self.radio = radio
        self.onBroadcastToggle = onBroadcastToggle
        self.onEdit = onEdit
    }

    public var body: some View {
        let isLive = radio.isBroadcasting(stationID: station.id)
        let nowPlaying = radio.currentItemByStation[station.id]

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Label("Library Radio", systemImage: "music.house")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                    Text(station.name)
                        .font(.largeTitle).fontWeight(.semibold)
                        .textSelection(.enabled)
                }

                // Filter summary
                VStack(alignment: .leading, spacing: 6) {
                    Text("FILTER")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    if config.query.genreTags.isEmpty {
                        Text("Whole library — no genre filter")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 80), spacing: 6)],
                            alignment: .leading, spacing: 6
                        ) {
                            ForEach(config.query.genreTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                                    )
                            }
                        }
                    }
                    if config.query.yearMin != nil || config.query.yearMax != nil {
                        let yMin = config.query.yearMin.map { "\($0)" } ?? "—"
                        let yMax = config.query.yearMax.map { "\($0)" } ?? "—"
                        Text("Years \(yMin) – \(yMax)")
                            .font(.callout.monospacedDigit())
                    }
                    Text("Seeds itself from your library and your taste signals — boosts, ♥s and skips reshape every lap.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Status / now-playing
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: isLive ? "dot.radiowaves.left.and.right" : "pause.circle")
                            .foregroundStyle(isLive ? .red : .secondary)
                        Text(isLive ? "ON AIR" : "OFF AIR")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(isLive ? .red : .secondary)
                            .tracking(0.8)
                    }

                    if let item = nowPlaying {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? "—")
                                .font(.title3).fontWeight(.medium)
                            if let artist = item.artist {
                                Text(artist)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if item.historyID != nil {
                            dislikeButton(for: item)
                        }
                    } else if isLive {
                        Text("Choosing the first track from your library…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Click **Start Broadcast** to play your own library, ranked by taste. Starts instantly — the files are already here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button(action: onBroadcastToggle) {
                            Label(isLive ? "Stop Broadcast" : "Start Broadcast",
                                  systemImage: isLive ? "stop.fill" : "play.fill")
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(isLive ? .red : .accentColor)

                        Button(action: onEdit) {
                            Label("Edit Filters…", systemImage: "slider.horizontal.3")
                        }
                        .controlSize(.large)
                        .help(isLive
                              ? "Change what this station plays. Saving restarts it."
                              : "Change what this station plays")
                    }
                }

                if isLive, let local = radio.streamURL(for: station) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("STREAM")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .tracking(0.8)
                        Text(local.absoluteString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Spacer()
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .navigationTitle(station.name)
    }

    @ViewBuilder
    private func dislikeButton(for item: TrackSourceItem) -> some View {
        let skipped = skippedByURL[item.url] == true
        Button {
            skippedByURL[item.url] = true
            Task { await radio.skipCurrent(stationID: station.id) }
        } label: {
            Label(
                skipped ? "Skipped" : "Skip",
                systemImage: skipped ? "hand.thumbsdown.fill" : "hand.thumbsdown"
            )
        }
        .buttonStyle(.bordered)
        .tint(skipped ? .orange : .secondary)
        .disabled(skipped)
    }
}
#endif
