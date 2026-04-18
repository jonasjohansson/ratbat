#if os(macOS)
import SwiftUI

/// Sheet for creating a new Last.fm-backed radio station.
///
/// Mirrors ``AddNTSStationView`` in shape so the two sources feel like
/// siblings in the UI: pick a name, pick at least one tag, optionally
/// constrain year. The created station is persisted via
/// ``StationManager/createLastFM(_:)`` and appears in the sidebar.
/// First-track resolution happens later, the first time the user clicks
/// broadcast — creation itself makes no network calls.
///
/// v1 scope: a curated popular-tag picker + optional year-range filter
/// (range is stored but not enforced yet — Last.fm's `tag.getTopTracks`
/// doesn't surface per-track year, and MusicBrainz cross-referencing is
/// deferred). Tag entry is pick-from-list only; free-text tags are
/// out-of-scope for the first pass.
///
/// Also surfaces the Last.fm API key field when the user hasn't pasted
/// one yet. Once saved in preferences, subsequent visits hide it.
public struct AddLastFMStationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var stations: StationManager
    @ObservedObject public var preferences: BroadcastPreferences

    @State private var name: String = ""
    @State private var selectedTags: Set<String> = []
    @State private var yearMinString: String = ""
    @State private var yearMaxString: String = ""
    @State private var apiKeyDraft: String = ""

    // Filter suite — defaults mirror FacetedQuery's defaults so
    // "just click Create" yields the same pool shape as pre-filter-UI.
    // Precision UI was removed as part of the faceted migration;
    // LastFMStationController hard-codes .verified behavior for now —
    // Task 6 will formalize this.
    @State private var tagMode: TagMatch = .any
    @State private var popularity: PopularityTier = .middle
    @State private var excludeOwnedLibrary: Bool = false

    /// Curated list of popular Last.fm tags. Ordered by rough popularity
    /// and clustered loosely by vibe so the picker reads as a genre
    /// palette rather than an alphabetical phone book.
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
                    TextField("0943b6f7…", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Register a free key at last.fm/api/account/create")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("90s Techno", text: $name)
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
                .frame(maxHeight: 240)
            }

            DisclosureGroup("Filters") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Tag mode", selection: $tagMode) {
                        Text("Any tag matches (broad)").tag(TagMatch.any)
                        Text("All tags must match (narrow)").tag(TagMatch.all)
                    }
                    .pickerStyle(.segmented)

                    Picker("Popularity", selection: $popularity) {
                        Text("Hits — top 10%").tag(PopularityTier.hits)
                        Text("Middle — 10–50%").tag(PopularityTier.middle)
                        Text("Deep cuts — bottom 50%").tag(PopularityTier.deepCuts)
                    }
                    .pickerStyle(.menu)

                    Toggle("Only surprise me — exclude my library", isOn: $excludeOwnedLibrary)

                    HStack {
                        Text("Year range (stored, not enforced):")
                        TextField("1990", text: $yearMinString)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("—")
                        TextField("1994", text: $yearMaxString)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    .font(.caption)

                    Text("Tip: pair a genre tag with a decade tag like \"1990s\" — that's a cheap approximation of year filtering.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

    /// Name + at least one tag required. If the user hasn't saved an API
    /// key yet, also require one in the draft field so the created
    /// station can actually broadcast. Year fields remain optional.
    private var canSubmit: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasTag = !selectedTags.isEmpty
        let hasKey = !preferences.lastFMAPIKey.isEmpty
            || !apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
        return hasName && hasTag && hasKey
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedKey.isEmpty {
            preferences.lastFMAPIKey = trimmedKey
        }
        let query = FacetedQuery(
            genreTags: Array(selectedTags),
            yearMin: Int(yearMinString),
            yearMax: Int(yearMaxString),
            tagMatch: tagMode,
            popularity: popularity,
            excludeOwnedLibrary: excludeOwnedLibrary
        )
        let config = LastFMStationConfig(name: trimmedName, query: query)
        stations.createLastFM(config)
        dismiss()
    }
}
#endif
