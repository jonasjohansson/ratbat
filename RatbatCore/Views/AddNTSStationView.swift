#if os(macOS)
import SwiftUI

/// Sheet for creating a new NTS-backed radio station.
///
/// The user picks a name and one-or-more tags; the station is then
/// persisted via ``StationManager/createNTS(_:)`` and appears in the
/// sidebar. Clicking broadcast on it later constructs an
/// ``NTSStationController`` + ``NTSSource`` on the fly (see
/// ``RadioBroadcaster/startBroadcast(station:)``), so creation itself
/// is quick — no subprocess / network I/O happens until the user
/// actually hits play.
///
/// v1 scope: a curated ~25-tag picker + an optional year-range filter
/// (the year filter is wired into ``NTSStationConfig`` but acts as a
/// soft guide; the controller's year filtering ships in a later task).
/// Free-text tag entry and a live tag browser sourced from NTS are
/// out-of-scope for this first pass.
public struct AddNTSStationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var stations: StationManager

    @State private var name: String = ""
    @State private var selectedTags: Set<String> = []
    @State private var yearMinString: String = ""
    @State private var yearMaxString: String = ""

    /// Curated list of common NTS genre/mood tags. Sourced from a quick
    /// pass through what the NTS API actually returns — a later task
    /// will replace this with a live-fetched list.
    private static let availableTags: [String] = [
        "ambient", "electronic", "techno", "house",
        "jazz", "experimental", "hip hop", "ECM",
        "new age", "downtempo", "drum and bass",
        "soul", "funk", "disco", "post-punk",
        "minimal", "drone", "dub", "global",
        "field recordings", "lo-fi", "piano",
        "classical", "modern classical", "noise"
    ]

    public init(stations: StationManager) {
        self.stations = stations
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New NTS Station")
                .font(.title3).fontWeight(.semibold)

            Text("Seeded by NTS Radio shows. Picks a fresh track from DJs tagged with your picks, never plays the same one twice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Saturday Ambient", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tags (pick at least one)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120), spacing: 4)],
                    spacing: 4
                ) {
                    ForEach(Self.availableTags, id: \.self) { tag in
                        Toggle(tag, isOn: Binding(
                            get: { selectedTags.contains(tag) },
                            set: { isOn in
                                if isOn {
                                    selectedTags.insert(tag)
                                } else {
                                    selectedTags.remove(tag)
                                }
                            }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                }
                .frame(maxHeight: 200)
            }

            DisclosureGroup("Filters (optional)") {
                HStack {
                    Text("Year range:")
                    TextField("2000", text: $yearMinString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("—")
                    TextField("2026", text: $yearMaxString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Name + at least one tag required. Year fields are optional; we
    /// don't validate them here — bad input parses to `nil` and the
    /// controller treats that as "no filter".
    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !selectedTags.isEmpty
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let config = NTSStationConfig(
            name: trimmedName,
            tags: Array(selectedTags),
            yearMin: Int(yearMinString),
            yearMax: Int(yearMaxString)
        )
        stations.createNTS(config)
        dismiss()
    }
}
#endif
