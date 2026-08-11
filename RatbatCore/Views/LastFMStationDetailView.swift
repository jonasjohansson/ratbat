#if os(macOS)
import SwiftUI

/// Detail pane shown when the user selects a Last.fm-backed station in
/// the sidebar. Mirrors ``NTSStationDetailView`` — tracks are resolved
/// on demand so a plain track list doesn't make sense; we show the
/// station's config + broadcast state + now-playing instead.
public struct LastFMStationDetailView: View {
    public let station: Station
    public let config: LastFMStationConfig
    @ObservedObject public var radio: RadioBroadcaster
    public let onBroadcastToggle: () -> Void
    /// Raised when the user asks to change the station's facets. The
    /// sheet lives in ``RootView`` — the detail pane doesn't own the
    /// station catalogue, and shouldn't have to, so it reports the intent
    /// the same way it reports a broadcast toggle.
    public let onEdit: () -> Void

    /// Per-URL saved state for the ♥ button so moving to the next track
    /// resets the button but keeping it pressed on the current track
    /// reads as "saved" until playback moves on.
    @State private var savedByURL: [URL: Bool] = [:]
    @State private var saveInFlight: Bool = false
    @State private var saveError: String?
    @State private var skippedByURL: [URL: Bool] = [:]

    public init(
        station: Station,
        config: LastFMStationConfig,
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
                    Label("Last.fm Station", systemImage: "chart.bar.xaxis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                    Text(station.name)
                        .font(.largeTitle).fontWeight(.semibold)
                        .textSelection(.enabled)
                }

                // Tags
                VStack(alignment: .leading, spacing: 6) {
                    Text("TAGS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    FlowingTagList(tags: config.query.genreTags)
                }

                // Year range (if set)
                if config.query.yearMin != nil || config.query.yearMax != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YEAR")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .tracking(0.8)
                        let yMin = config.query.yearMin.map { "\($0)" } ?? "—"
                        let yMax = config.query.yearMax.map { "\($0)" } ?? "—"
                        Text("\(yMin) – \(yMax)")
                            .font(.callout.monospacedDigit())
                        Text("Stored for reference; not enforced in v1 — tag filtering drives selection.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
                            HStack(spacing: 10) {
                                likeButton(for: item)
                                dislikeButton(for: item)
                            }
                        }
                        if let err = saveError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else if isLive {
                        Text("Resolving first track from Last.fm…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Click **Start Broadcast** to pull top tracks for your tags from Last.fm. First track takes ~15 s while we resolve it on YouTube.")
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

                        // Editing the tags keeps the station's id, and with
                        // it every play, save and skip it has recorded.
                        // Deleting and recreating does not.
                        Button(action: onEdit) {
                            Label("Edit Tags…", systemImage: "slider.horizontal.3")
                        }
                        .controlSize(.large)
                        .help(isLive
                              ? "Change what this station looks for. Saving restarts it."
                              : "Change what this station looks for")
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

    @ViewBuilder
    private func likeButton(for item: TrackSourceItem) -> some View {
        let saved = savedByURL[item.url] == true
        Button {
            saveError = nil
            saveInFlight = true
            Task {
                let response = await radio.likeCurrent(stationID: station.id)
                saveInFlight = false
                if response.status == "saved" {
                    savedByURL[item.url] = true
                } else {
                    saveError = response.message ?? "Save failed"
                }
            }
        } label: {
            Label(
                saved ? "Saved" : "Save to Library",
                systemImage: saved ? "heart.fill" : "heart"
            )
        }
        .buttonStyle(.bordered)
        .tint(saved ? .red : .accentColor)
        .disabled(saved || saveInFlight)
    }
}

/// Lightweight tag chip row that wraps to multiple lines. Shared helper
/// kept inside this file for now — if NTSStationDetailView's tag row ever
/// needs wrapping behaviour too, promote this into a common place.
private struct FlowingTagList: View {
    let tags: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
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
}
#endif
