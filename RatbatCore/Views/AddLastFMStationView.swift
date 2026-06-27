#if os(macOS)
import SwiftUI

/// Sheet for creating a new Last.fm-backed radio station.
///
/// Mirrors ``AddNTSStationView`` in shape so the two sources feel like
/// siblings in the UI: pick a name, pick at least one tag, optionally
/// constrain era/region. The created station is persisted via
/// ``StationManager/createLastFM(_:)`` and appears in the sidebar.
/// First-track resolution happens later, the first time the user clicks
/// broadcast — creation itself makes no network calls.
///
/// The genre / era / region facets are delegated to the shared
/// ``FacetedQueryEditor`` subview so all source sheets expose the same
/// vocabulary. Last.fm-specific controls (tag mode, popularity tier,
/// "exclude my library" toggle) live in a collapsed `DisclosureGroup`
/// below the editor.
///
/// Also surfaces the Last.fm API key field when the user hasn't pasted
/// one yet. Once saved in preferences, subsequent visits hide it.
public struct AddLastFMStationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var stations: StationManager
    @ObservedObject public var preferences: BroadcastPreferences

    @State private var name: String = ""
    @State private var apiKeyDraft: String = ""

    /// All facet state lives in a single ``FacetedQuery`` value. Nested
    /// bindings (`$query.tagMatch` etc.) work because `@State` wraps a
    /// struct — SwiftUI re-renders whenever any field mutates. Defaults
    /// come from `FacetedQuery`'s own init: `.any` tagMatch, `.middle`
    /// popularity, `excludeOwnedLibrary = false`.
    @State private var query = FacetedQuery(genreTags: [])
    /// Explore ↔ Comfort dial for the new station. Mirrors
    /// ``LastFMStationConfig/exploration``; gentle comfort lean by default.
    @State private var exploration: Double = 0.25

    /// Curated list of popular Last.fm tags. Ordered by rough popularity
    /// and clustered loosely by vibe so the picker reads as a genre
    /// palette rather than an alphabetical phone book. Passed into the
    /// shared ``FacetedQueryEditor`` as its `palette`.
    private static let availableTags: [String] = [
        "techno", "house", "deep house", "minimal",
        "ambient", "drone", "downtempo", "trip hop",
        "jazz", "jazz fusion", "soul", "funk",
        "disco", "krautrock", "psychedelic",
        "experimental", "electronic", "idm",
        "drum and bass", "dubstep", "dub",
        "hip hop", "new wave", "post-punk",
        "indie", "shoegaze", "dream pop",
        "classical", "modern classical", "piano",
        "1970s", "1980s", "1990s", "2000s", "2010s", "2020s"
    ]

    public init(stations: StationManager, preferences: BroadcastPreferences) {
        self.stations = stations
        self.preferences = preferences
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Last.fm Station")
                .font(.title3).fontWeight(.semibold)

            Text("Seeded by Last.fm's top tracks for the tags you pick. Dedupes against history so the same song never plays twice for the station.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if preferences.lastFMAPIKey.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last.fm API key (paste once, saved in preferences)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("paste your API key", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Register a free key at last.fm/api/account/create")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField(query.suggestedName, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            FacetedQueryEditor(query: $query, palette: Self.availableTags)

            DisclosureGroup("Last.fm filters") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Tag mode", selection: $query.tagMatch) {
                        Text("Any tag matches (broad)").tag(TagMatch.any)
                        Text("All tags must match (narrow)").tag(TagMatch.all)
                    }
                    .pickerStyle(.segmented)

                    Picker("Popularity", selection: $query.popularity) {
                        Text("Hits — top 10%").tag(PopularityTier.hits)
                        Text("Middle — 10–50%").tag(PopularityTier.middle)
                        Text("Deep cuts — bottom 50%").tag(PopularityTier.deepCuts)
                    }
                    .pickerStyle(.menu)

                    Toggle("Only surprise me — exclude my library", isOn: $query.excludeOwnedLibrary)

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

    /// At least one tag required. If the user hasn't saved an API key
    /// yet, also require one in the draft field so the created station
    /// can actually broadcast. Name is optional — when blank, `create()`
    /// falls back to ``FacetedQuery/suggestedName``. Era/region remain
    /// optional narrowing knobs.
    private var canSubmit: Bool {
        let hasTag = !query.genreTags.isEmpty
        let hasKey = !preferences.lastFMAPIKey.isEmpty
            || !apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
        return hasTag && hasKey
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmedName.isEmpty ? query.suggestedName : trimmedName
        let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedKey.isEmpty {
            preferences.lastFMAPIKey = trimmedKey
        }
        let config = LastFMStationConfig(name: finalName, query: query, exploration: exploration)
        stations.createLastFM(config)
        dismiss()
    }
}
#endif
