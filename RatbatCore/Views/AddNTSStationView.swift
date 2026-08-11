#if os(macOS)
import SwiftUI

/// Sheet for creating a new NTS-backed radio station.
///
/// The user picks a name (optional — falls back to ``FacetedQuery/suggestedName``
/// when blank) and one-or-more facets via the shared
/// ``FacetedQueryEditor``. The station is persisted via
/// ``StationManager/createNTS(_:)`` and appears in the sidebar. Clicking
/// broadcast on it later constructs an ``NTSStationController`` +
/// ``NTSSource`` on the fly (see
/// ``RadioBroadcaster/startBroadcast(station:)``), so creation itself
/// is quick — no subprocess / network I/O happens until the user
/// actually hits play.
///
/// Mirrors ``AddLastFMStationView`` in shape so the sources feel like
/// siblings in the UI: genre / era / region via the shared editor, plus
/// a collapsed disclosure for the per-source knobs that only apply to
/// certain controllers. NTS's pipeline honors `tagMatch` and
/// `excludeOwnedLibrary`; popularity is a Last.fm-only signal and is
/// hidden here.
public struct AddNTSStationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var stations: StationManager

    @State private var name: String = ""

    /// All facet state lives in a single ``FacetedQuery`` value. Nested
    /// bindings (`$query.tagMatch` etc.) work because `@State` wraps a
    /// struct — SwiftUI re-renders whenever any field mutates.
    @State private var query = FacetedQuery(genreTags: [])


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
                TextField(query.suggestedName, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            FacetedQueryEditor(query: $query, palette: StationTagPalette.nts)

            DisclosureGroup("NTS filters") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Tag mode", selection: $query.tagMatch) {
                        Text("Any tag matches (broad)").tag(TagMatch.any)
                        Text("All tags must match (narrow)").tag(TagMatch.all)
                    }
                    .pickerStyle(.segmented)

                    Toggle("Only surprise me — exclude my library", isOn: $query.excludeOwnedLibrary)
                }
                .padding(.top, 4)
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
        .frame(width: 540)
    }

    /// At least one tag required. Name is optional — when blank,
    /// `create()` falls back to ``FacetedQuery/suggestedName``.
    /// Era / region remain optional narrowing knobs.
    private var canSubmit: Bool {
        !query.genreTags.isEmpty
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmedName.isEmpty ? query.suggestedName : trimmedName
        let config = NTSStationConfig(name: finalName, query: query)
        stations.createNTS(config)
        dismiss()
    }
}
#endif
