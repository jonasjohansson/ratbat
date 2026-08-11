#if os(macOS)
import SwiftUI

/// Sheet for changing an existing generative station's name and facets.
///
/// The counterpart to the three "Add station" sheets, and deliberately the
/// same controls in the same order — a station you edit should look like
/// the station you created. It is one view for all three sources rather
/// than three near-identical ones; the only per-source difference is the
/// tag palette and, for Bandcamp, the sort dimension.
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
    @State private var saving = false

    private let palette: [String]
    private let isBandcamp: Bool
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
            self.sourceLabel = "NTS"
            self._sort = State(initialValue: .date)
        case .lastFM(let config):
            self._query = State(initialValue: config.query)
            self.palette = StationTagPalette.lastFM
            self.isBandcamp = false
            self.sourceLabel = "Last.fm"
            self._sort = State(initialValue: .date)
        case .bandcamp(let config):
            self._query = State(initialValue: config.query)
            self.palette = StationTagPalette.bandcamp
            self.isBandcamp = true
            self.sourceLabel = "Bandcamp"
            self._sort = State(initialValue: config.sort)
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
                    Toggle(
                        "Only surprise me — exclude my library",
                        isOn: $query.excludeOwnedLibrary
                    )
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
                    .disabled(query.genreTags.isEmpty || saving)
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
        if !trimmed.isEmpty, trimmed != station.name {
            stations.rename(station.id, to: trimmed)
        }
        var updated = stations.updateQuery(station.id, to: query)
        if isBandcamp {
            updated = stations.updateBandcampSort(station.id, to: sort) ?? updated
        }
        guard let updated else {
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
