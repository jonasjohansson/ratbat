#if os(macOS)
import SwiftUI

/// Sheet for creating a new Library Radio station — the self-seeding
/// kind that plays only tracks the owner already has, ranked by the
/// taste profile (signal-model design §4).
///
/// Mirrors ``AddNTSStationView`` in shape so the kinds feel like
/// siblings, with two honest differences:
/// - the palette is empty (the shared vocabularies are Last.fm/NTS/
///   Bandcamp taxonomies, not this library's genre tags) — tags are
///   free-text and filter against the files' own genre fields;
/// - zero tags is a VALID submission meaning "the whole library", so
///   the create button never gates on tag count the way the generative
///   sheets do.
///
/// The region picker and popularity tier are not rendered at all: local
/// files carry no artist-country or listener-count metadata, and a
/// control that silently does nothing is worse than no control (see
/// ``LibraryRadioStationConfig`` for the facet contract).
public struct AddLibraryRadioStationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var stations: StationManager

    @State private var name: String = ""
    @State private var query = FacetedQuery(genreTags: [])
    @State private var freeTextTag: String = ""
    @State private var yearMinString: String = ""
    @State private var yearMaxString: String = ""

    public init(stations: StationManager) {
        self.stations = stations
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Library Radio")
                .font(.title3).fontWeight(.semibold)

            Text("Plays your own library, ranked by taste. Boosts, ♥s and skips reshape every lap — leave the filters empty for everything you have.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField(namePlaceholder, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            genreSection
            eraSection

            DisclosureGroup("Library filters") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Tag mode", selection: $query.tagMatch) {
                        Text("Any tag matches (broad)").tag(TagMatch.any)
                        Text("All tags must match (narrow)").tag(TagMatch.all)
                    }
                    .pickerStyle(.segmented)
                    Text("Tags match your files' genre fields. Region and popularity filters don't exist here — file tags carry neither.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            yearMinString = query.yearMin.map(String.init) ?? ""
            yearMaxString = query.yearMax.map(String.init) ?? ""
        }
    }

    private var namePlaceholder: String {
        query.genreTags.isEmpty ? "Library Radio" : query.suggestedName
    }

    /// Free-text tag entry + removable chips. Deliberately NOT the shared
    /// ``FacetedQueryEditor``: that editor renders a region section this
    /// kind cannot honor, and honesty beats reuse when the alternative is
    /// a picker wired to nothing.
    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Genre (optional — empty = whole library)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("e.g. ambient", text: $freeTextTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addFreeTextTag() }
                Button("Add") { addFreeTextTag() }
                    .disabled(freeTextTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !query.genreTags.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120), spacing: 4)],
                    spacing: 4
                ) {
                    ForEach(query.genreTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag).font(.caption)
                            Button {
                                query.genreTags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
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
    }

    private var eraSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Era (optional — files without a year tag are excluded while set)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("From", text: $yearMinString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onChange(of: yearMinString) { _, new in
                        query.yearMin = Int(new.trimmingCharacters(in: .whitespaces))
                    }
                Text("–").foregroundStyle(.secondary)
                TextField("To", text: $yearMaxString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onChange(of: yearMaxString) { _, new in
                        query.yearMax = Int(new.trimmingCharacters(in: .whitespaces))
                    }
            }
        }
    }

    private func addFreeTextTag() {
        let tag = freeTextTag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty else { return }
        if !query.genreTags.contains(tag) {
            query.genreTags.append(tag)
        }
        freeTextTag = ""
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // Through the validated surface the web CRUD also rides —
        // `.libraryRadio` is the draft the manager exempts from the
        // one-tag rule, so a throw here is unreachable and `try?`
        // acknowledges the signature (the AddNTSStationView posture).
        _ = try? stations.createStation(
            .libraryRadio(query: query, shufflePool: true),
            name: trimmedName.isEmpty ? nil : trimmedName
        )
        dismiss()
    }
}
#endif
