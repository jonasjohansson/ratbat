#if os(macOS)
import SwiftUI

/// Shared facet-editing subview used by the per-source "Add station"
/// sheets (Last.fm, Bandcamp, …). Three sections — genre (curated
/// palette + free text), optional era (year range), optional region
/// (ISO alpha-2 codes) — bound to a caller-supplied ``FacetedQuery``.
///
/// The caller supplies the curated ``palette`` so each source can lean
/// into its own vocabulary (Last.fm's tag cloud ≠ Bandcamp's genre
/// taxonomy). Tags not in the palette still round-trip through the
/// query and show up as removable chips below the palette grid.
public struct FacetedQueryEditor: View {
    @Binding var query: FacetedQuery
    let palette: [String]

    @State private var freeTextTag: String = ""
    @State private var yearMinString: String = ""
    @State private var yearMaxString: String = ""
    @State private var regionPopoverOpen: Bool = false

    public init(query: Binding<FacetedQuery>, palette: [String]) {
        self._query = query
        self.palette = palette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            genreSection
            eraSection
            regionSection
        }
        .onAppear {
            yearMinString = query.yearMin.map(String.init) ?? ""
            yearMaxString = query.yearMax.map(String.init) ?? ""
        }
    }

    // MARK: - Sections

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Genre").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: 4)],
                spacing: 4
            ) {
                ForEach(palette, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(
                        get: { query.genreTags.contains(tag) },
                        set: { isOn in
                            if isOn {
                                if !query.genreTags.contains(tag) {
                                    query.genreTags.append(tag)
                                }
                            } else {
                                query.genreTags.removeAll { $0 == tag }
                            }
                        }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }

            HStack {
                TextField("Add tag…", text: $freeTextTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addFreeText() }
                Button("Add") { addFreeText() }
                    .disabled(freeTextTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !customTags.isEmpty {
                // Free-text / non-palette tags surface here as removable
                // chips. Tapping anywhere on the chip removes it.
                FlowRow(spacing: 6) {
                    ForEach(customTags, id: \.self) { tag in
                        Label(tag, systemImage: "xmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .onTapGesture { query.genreTags.removeAll { $0 == tag } }
                    }
                }
            }
        }
    }

    private var eraSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Era (optional)").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("1990", text: $yearMinString)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: yearMinString) { _, newValue in
                        query.yearMin = Int(newValue)
                    }
                Text("—")
                TextField("1999", text: $yearMaxString)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: yearMaxString) { _, newValue in
                        query.yearMax = Int(newValue)
                    }
            }
        }
    }

    private var regionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Region (optional)").font(.caption).foregroundStyle(.secondary)
            FlowRow(spacing: 6) {
                ForEach(query.regions, id: \.self) { code in
                    Label(
                        Locale.current.localizedString(forRegionCode: code) ?? code,
                        systemImage: "xmark.circle.fill"
                    )
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .onTapGesture { query.regions.removeAll { $0 == code } }
                }
                Button("+ Add region") { regionPopoverOpen.toggle() }
                    .popover(isPresented: $regionPopoverOpen) {
                        RegionPicker { code in
                            if !query.regions.contains(code) {
                                query.regions.append(code)
                            }
                            regionPopoverOpen = false
                        }
                    }
            }
        }
    }

    // MARK: - Helpers

    /// Tags that live in ``query.genreTags`` but aren't part of the
    /// caller-supplied ``palette``. Rendered as removable chips so the
    /// user can see and tear down anything they typed by hand.
    private var customTags: [String] {
        query.genreTags.filter { !palette.contains($0) }
    }

    private func addFreeText() {
        let trimmed = freeTextTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !query.genreTags.contains(trimmed) else {
            freeTextTag = ""
            return
        }
        query.genreTags.append(trimmed)
        freeTextTag = ""
    }
}

// MARK: - Region picker popover

/// Two-column list (name + ISO code) backed by the current SDK's
/// region enumeration. Displays `Locale.current.localizedString(...)`
/// so users see "Japan", but stores the alpha-2 code ("JP") in the
/// underlying query.
private struct RegionPicker: View {
    let onPick: (String) -> Void
    @State private var search: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(filtered, id: \.self) { code in
                Button {
                    onPick(code)
                } label: {
                    HStack {
                        Text(Locale.current.localizedString(forRegionCode: code) ?? code)
                        Spacer()
                        Text(code).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: 280, height: 320)
        }
    }

    /// All ISO 3166 alpha-2 region codes sorted by localized name so
    /// "Japan" lands near "J" rather than at "JP" in an alpha sort.
    /// `Locale.Region.isoRegions` replaces the deprecated
    /// `Locale.isoRegionCodes` and returns ``Locale.Region`` values —
    /// we pull `.identifier` to get the alpha-2 string.
    private static let allRegionCodes: [String] = {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 }  // drop "001" world / subregion numerics
            .sorted { a, b in
                let la = Locale.current.localizedString(forRegionCode: a) ?? a
                let lb = Locale.current.localizedString(forRegionCode: b) ?? b
                return la.localizedCaseInsensitiveCompare(lb) == .orderedAscending
            }
    }()

    private var filtered: [String] {
        guard !search.isEmpty else { return Self.allRegionCodes }
        let needle = search.lowercased()
        return Self.allRegionCodes.filter { code in
            if code.lowercased().contains(needle) { return true }
            let name = Locale.current.localizedString(forRegionCode: code) ?? ""
            return name.lowercased().contains(needle)
        }
    }
}

// MARK: - FlowRow

/// Minimal flow layout so chip rows wrap onto a new line once the
/// available width is exhausted. A horizontal `HStack` would clip
/// once the user adds more than a handful of custom tags or regions,
/// and pulling in a bigger layout library for three chips isn't
/// worth it.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
