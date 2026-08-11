#if os(macOS)
import SwiftUI

/// Detail pane shown when the user selects a Bandcamp-backed station in
/// the sidebar. Mirrors ``LastFMStationDetailView`` — tracks are resolved
/// on demand so a plain track list doesn't make sense; we surface the
/// station's facets (genre tags, year range, regions) as read-only chips
/// plus the shared broadcast controls (On Air badge, Start/Stop, stream
/// URL) and ICY save/skip buttons.
///
/// Differences from Last.fm:
/// - Header label + icon reflect Bandcamp, not the Last.fm chart glyph.
/// - Popularity / tag-match aren't shown — the Bandcamp controller
///   ignores them, and the add-station sheet hides them too. Instead,
///   Bandcamp's ``BandcampClient/Sort`` dimension and the
///   `excludeOwnedLibrary` toggle are surfaced as chips.
/// - Shuffle-pool is omitted to keep v1 parity with the Last.fm detail
///   view (which also hides it).
public struct BandcampStationDetailView: View {
    public let station: Station
    public let config: BandcampStationConfig
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
        config: BandcampStationConfig,
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
                    Label("Bandcamp Station", systemImage: "opticaldisc")
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
                    FlowingChipList(items: config.query.genreTags)
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

                // Regions (if any)
                if !config.query.regions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("REGIONS")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .tracking(0.8)
                        FlowingChipList(items: config.query.regions)
                    }
                }

                // Bandcamp-specific filter chips — sort + library-exclude.
                // Popularity / tag-match deliberately omitted (ignored by
                // the Bandcamp controller; not shown in the add sheet).
                VStack(alignment: .leading, spacing: 6) {
                    Text("FILTERS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    FlowingChipList(items: filterChips)
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
                        Text("Resolving first track from Bandcamp…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Click **Start Broadcast** to pull recent releases for your tags from Bandcamp. First track takes ~15 s while we resolve it on YouTube.")
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

    /// Flatten the Bandcamp-specific knobs into a chip row. The sort
    /// dimension always shows (even at its default) because it meaningfully
    /// changes the feed; the library-exclude chip only surfaces when the
    /// user actually enabled it, matching how the add sheet treats the toggle
    /// as opt-in.
    private var filterChips: [String] {
        var chips: [String] = []
        switch config.sort {
        case .date: chips.append("Sort: Newest")
        case .pop:  chips.append("Sort: Popular")
        }
        if config.query.excludeOwnedLibrary {
            chips.append("Exclude My Library")
        }
        return chips
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

/// Lightweight chip row that wraps to multiple lines. Local to this file
/// to avoid colliding with ``LastFMStationDetailView``'s private
/// `FlowingTagList` — if either view grows a third caller, promote into
/// a shared helper.
private struct FlowingChipList: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
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
