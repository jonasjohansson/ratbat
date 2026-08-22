#if os(macOS)
import SwiftUI

/// Sheet for changing an existing generative station's name and facets.
///
/// The counterpart to the three "Add station" sheets, and deliberately the
/// same controls in the same order — a station you edit should look like
/// the station you created. It is one view for all three sources rather
/// than three near-identical ones; the only per-source differences are the
/// tag palette, Bandcamp's sort dimension, and Last.fm's popularity tier
/// and Comfort ↔ Explore dial.
///
/// ## The restart is stated, not sprung
///
/// A generative station builds its pool once, at broadcast start. New tags
/// therefore change nothing anyone can hear until the pipeline is rebuilt,
/// and rebuilding it cuts the track that is playing. Rather than restart
/// silently (a listener hears the music stop for no visible reason) or
/// never restart (the user changes the tags and nothing happens, which
/// reads as a bug), the sheet says which one is about to happen: while the
/// station is on air the confirm button reads **Save & Restart** and a
/// notice above it spells out the consequence. Off air, it is just **Save**.
public struct EditStationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var stations: StationManager
    @ObservedObject public var radio: RadioBroadcaster

    public let station: Station

    @State private var name: String
    @State private var query: FacetedQuery
    @State private var sort: BandcampClient.Sort
    /// Comfort ↔ Explore dial, Last.fm only. Initialised from the config
    /// so the slider shows where the dial currently sits; carries a
    /// placeholder default for the other sources, where it never renders.
    @State private var exploration: Double
    @State private var saving = false

    private let palette: [String]
    private let isBandcamp: Bool
    private let isLastFM: Bool
    private let isLibraryRadio: Bool
    private let sourceLabel: String

    /// Returns `nil` for a playlist-backed station: a fixed queue has no
    /// facets, so there is nothing here to edit. Callers use the optional
    /// initializer to decide whether to offer the button at all.
    public init?(
        station: Station,
        stations: StationManager,
        radio: RadioBroadcaster
    ) {
        switch station.kind {
        case .playlist:
            return nil
        case .nts(let config):
            self._query = State(initialValue: config.query)
            self.palette = StationTagPalette.nts
            self.isBandcamp = false
            self.isLastFM = false
            self.isLibraryRadio = false
            self.sourceLabel = "NTS"
            self._sort = State(initialValue: .date)
            self._exploration = State(initialValue: 0.25)
        case .lastFM(let config):
            self._query = State(initialValue: config.query)
            self.palette = StationTagPalette.lastFM
            self.isBandcamp = false
            self.isLastFM = true
            self.isLibraryRadio = false
            self.sourceLabel = "Last.fm"
            self._sort = State(initialValue: .date)
            self._exploration = State(initialValue: config.exploration)
        case .bandcamp(let config):
            self._query = State(initialValue: config.query)
            self.palette = StationTagPalette.bandcamp
            self.isBandcamp = true
            self.isLastFM = false
            self.isLibraryRadio = false
            self.sourceLabel = "Bandcamp"
            self._sort = State(initialValue: config.sort)
            self._exploration = State(initialValue: 0.25)
        case .libraryRadio(let config):
            // Empty palette: the curated vocabularies are external
            // taxonomies; this kind's tags match the files' own genre
            // fields, entered free-text in the shared editor.
            self._query = State(initialValue: config.query)
            self.palette = []
            self.isBandcamp = false
            self.isLastFM = false
            self.isLibraryRadio = true
            self.sourceLabel = "Library Radio"
            self._sort = State(initialValue: .date)
            self._exploration = State(initialValue: 0.25)
        }
        self.station = station
        self.stations = stations
        self.radio = radio
        self._name = State(initialValue: station.name)
    }

    private var isLive: Bool { radio.isBroadcasting(stationID: station.id) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(sourceLabel) Station")
                .font(.title3).fontWeight(.semibold)

            Text("The station keeps its identity — its history, saves and skips all stay attached. Only what it looks for changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField(query.suggestedName, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            FacetedQueryEditor(query: $query, palette: palette)

            DisclosureGroup("\(sourceLabel) filters") {
                VStack(alignment: .leading, spacing: 10) {
                    if isBandcamp {
                        Picker("Sort", selection: $sort) {
                            Text("Newest releases").tag(BandcampClient.Sort.date)
                            Text("Popular").tag(BandcampClient.Sort.pop)
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Picker("Tag mode", selection: $query.tagMatch) {
                            Text("Any tag matches (broad)").tag(TagMatch.any)
                            Text("All tags must match (narrow)").tag(TagMatch.all)
                        }
                        .pickerStyle(.segmented)
                    }
                    // Last.fm's extra knobs, mirroring AddLastFMStationView
                    // so editing can't do less than creating.
                    if isLastFM {
                        Picker("Popularity", selection: $query.popularity) {
                            Text("Hits — top 10%").tag(PopularityTier.hits)
                            Text("Middle — 10–50%").tag(PopularityTier.middle)
                            Text("Deep cuts — bottom 50%").tag(PopularityTier.deepCuts)
                        }
                        .pickerStyle(.menu)
                    }
                    if isLibraryRadio {
                        // No exclude-library toggle: every candidate IS
                        // the library. And say out loud which facets a
                        // local file cannot answer, instead of letting
                        // the shared editor's region section look wired.
                        Text("Tags and era filter your files' own tags; an era bound excludes files with no year tag. Regions and popularity aren't in file metadata and are ignored for this kind.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Toggle(
                            "Only surprise me — exclude my library",
                            isOn: $query.excludeOwnedLibrary
                        )
                    }
                    if isLastFM {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Comfort").font(.caption).foregroundStyle(.secondary)
                                Slider(value: $exploration, in: 0...1)
                                Text("Explore").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Comfort leans on artists you already love; Explore pushes more unfamiliar picks.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.top, 4)
            }

            if isLive {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("This station is on air. Saving rebuilds its pool, which **stops the track that is playing** and reconnects listeners. It stays on air afterwards.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isLive ? "Save & Restart" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    // Library Radio may save with zero tags — that is the
                    // "whole library" filter, the same carve-out the
                    // manager's validation makes.
                    .disabled((query.genreTags.isEmpty && !isLibraryRadio) || saving)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    /// Persist the edit, then rebuild the pipeline if the station is live.
    ///
    /// Order matters: the catalogue is written first, so a crash between
    /// the two leaves the station with its new tags and merely off air —
    /// recoverable — rather than broadcasting a config that was never
    /// saved.
    private func save() {
        saving = true
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // One atomic mutation through the same `applyUpdate` the web
        // `/stations/update` route rides — one persist, one @Published
        // tick, and no way for the sheet and the web to drift on edit
        // semantics. A throw is unreachable from this sheet (the confirm
        // button is disabled with no tags, and playlist stations never
        // get here), so `try?` + bail is an acknowledgement, not a path.
        var update = StationUpdate(
            name: (trimmed.isEmpty || trimmed == station.name) ? nil : trimmed,
            query: query
        )
        if isBandcamp { update.sort = sort }
        if isLastFM { update.exploration = exploration }
        guard let updated = try? stations.applyUpdate(station.id, update) else {
            saving = false
            dismiss()
            return
        }
        if isLive {
            Task {
                await radio.restartBroadcast(station: updated)
                saving = false
                dismiss()
            }
        } else {
            saving = false
            dismiss()
        }
    }
}
#endif
