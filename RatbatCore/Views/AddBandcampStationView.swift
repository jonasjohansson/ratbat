#if os(macOS)
import SwiftUI

/// Sheet for creating a new Bandcamp-backed radio station.
///
/// Mirrors ``AddLastFMStationView`` in shape — the two generative sources
/// should feel like siblings in the UI. Differences are driven by the
/// backing API:
///
/// - Bandcamp's `/api/discover/3/get_web` endpoint is unauthenticated, so
///   there is no API-key field (and therefore no ``BroadcastPreferences``
///   dependency).
/// - The filter disclosure surfaces Bandcamp's own ``BandcampClient/Sort``
///   dimension (`.date` for newest releases, `.pop` for most popular)
///   instead of Last.fm's tag-match / popularity-tier combo. Popularity
///   and tag-match live on ``FacetedQuery`` but are meaningless for the
///   Bandcamp controller — the curated palette + sort dimension is the
///   whole knob set the user actually twists.
/// - The ``FacetedQueryEditor`` palette leans into Bandcamp's long-tail
///   scene vocabulary — dungeon synth, hauntology, witch house, field
///   recording — rather than Last.fm's chart-weighted top tags.
///
/// The created station is persisted via ``StationManager/createBandcamp(_:)``
/// and appears in the sidebar. No network calls happen at creation time —
/// the first tag pool fetch runs lazily the first time the user clicks
/// broadcast, same as the Last.fm and NTS flows.
public struct AddBandcampStationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var stations: StationManager

    @State private var name: String = ""

    /// All facet state lives in a single ``FacetedQuery`` value. Same
    /// nested-binding pattern as ``AddLastFMStationView`` — `@State`
    /// wraps a struct so SwiftUI re-renders whenever any field mutates.
    /// Defaults come from `FacetedQuery`'s init.
    @State private var query = FacetedQuery(genreTags: [])

    /// Bandcamp-specific lifecycle flag. `.date` gives the user the
    /// "newest releases first" river that makes Bandcamp feel fresh;
    /// `.pop` backs off to tag-chart favourites when the user wants a
    /// more familiar cross-section. Default matches the config struct's
    /// default so the sheet mirrors what a minimal config would persist.
    @State private var sort: BandcampClient.Sort = .date

    /// Curated palette leaning into scenes where Bandcamp's long tail
    /// actually lives — the microgenres with active tag feeds but
    /// effectively no presence in Last.fm's chart-weighted vocabulary.
    /// Clustered loosely by vibe so the picker reads as a tour of the
    /// site's niches rather than an alphabetical list.
    private static let availableTags: [String] = [
        "techno", "house", "ambient", "dungeon synth",
        "vaporwave", "hyperpop", "drone", "dub techno",
        "outsider house", "idm", "breakcore", "footwork",
        "witch house", "hauntology", "slowcore", "shoegaze",
        "post-rock", "field recording", "lo-fi", "experimental"
    ]

    public init(stations: StationManager) {
        self.stations = stations
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Bandcamp Station")
                .font(.title3).fontWeight(.semibold)

            Text("Pulls recent releases from Bandcamp's public tag feed. Dedupes against history so the same track never plays twice for the station.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Dungeon Synth", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            FacetedQueryEditor(query: $query, palette: Self.availableTags)

            DisclosureGroup("Bandcamp filters") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Sort", selection: $sort) {
                        Text("Newest releases").tag(BandcampClient.Sort.date)
                        Text("Popular").tag(BandcampClient.Sort.pop)
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

    /// Name + at least one tag required. Era/region remain optional —
    /// Bandcamp's tag feed is the mandatory seed; everything else
    /// narrows an already-valid query.
    private var canSubmit: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasTag = !query.genreTags.isEmpty
        return hasName && hasTag
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let config = BandcampStationConfig(name: trimmedName, query: query, sort: sort)
        stations.createBandcamp(config)
        dismiss()
    }
}
#endif
