import Foundation

/// A radio station the broadcaster can serve.
///
/// Two concrete kinds ship today:
/// - ``Kind/playlist(queue:)`` — a pre-shuffled queue derived from a
///   user's library ``Playlist``.
/// - ``Kind/nts(config:)`` — a generative, NTS-backed station driven by
///   an ``NTSStationConfig`` (tags + optional year range).
///
/// The `Kind` enum is the source-of-truth for where tracks come from;
/// the old `seed: Seed` marker field has been retired. Convenience
/// accessors (``queue``, ``ntsConfig``) let existing call sites that
/// only care about one variant keep working.
///
/// `Sendable` + `Hashable` + `Identifiable` + `Codable` so stations
/// compose with the rest of the library types (selection tags, cache,
/// cross-actor passing, on-disk persistence through ``StationStore``).
public struct Station: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var kind: Kind

    /// Source-of-truth for where this station's tracks come from.
    /// Swift auto-synthesises Codable for enums with associated values
    /// as long as every associated payload is Codable — both
    /// ``playlist(queue:)`` and ``nts(config:)`` satisfy that.
    public enum Kind: Hashable, Sendable, Codable {
        /// Fixed, pre-shuffled queue. Replays the same tracks on every
        /// start — matches the pre-refactor behaviour.
        case playlist(queue: [Track])
        /// Generative NTS-backed station. Controller state (pool, history
        /// dedup, resolver) is reconstructed on each broadcast start from
        /// the config; the config itself is the persisted seed.
        case nts(config: NTSStationConfig)
    }

    public init(id: UUID = UUID(), name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    // MARK: - Convenience accessors

    /// Playlist queue, or `[]` for NTS stations. Lets existing code that
    /// only knows how to think in "tracks" (the sidebar row's track count,
    /// the detail pane's transient playlist view) keep compiling.
    public var queue: [Track] {
        if case let .playlist(q) = kind { return q }
        return []
    }

    /// NTS config, or `nil` for playlist stations. Mirrors ``queue`` for
    /// the other variant.
    public var ntsConfig: NTSStationConfig? {
        if case let .nts(c) = kind { return c }
        return nil
    }

    // MARK: - Factories

    /// Build a station seeded from a playlist. Auto-names as
    /// "Radio based on {playlist name}" so the sidebar immediately reads
    /// as what the user just did.
    public static func from(playlist: Playlist) -> Station {
        Station(
            name: "Radio based on \(playlist.name)",
            kind: .playlist(queue: playlist.tracks.shuffled())
        )
    }

    /// Build a station from an ``NTSStationConfig``. Reuses the config's
    /// `id` as the station id so ``HistoryStore`` dedup keys stay stable
    /// across broadcaster restarts.
    public static func fromNTS(_ config: NTSStationConfig) -> Station {
        Station(id: config.id, name: config.name, kind: .nts(config: config))
    }

    // MARK: - Slug

    /// URL-safe kebab-case identifier derived from ``name``. Used to route
    /// per-station stream URLs (`http://host:port/stream/{slug}.aac`) so
    /// multiple stations can broadcast concurrently on the same port.
    ///
    /// Derivation steps:
    /// 1. Strip diacritics via `folding(options:)` so "Äventyr" → "Aventyr".
    /// 2. Split on anything that isn't `[A-Za-z0-9]` — that collapses
    ///    whitespace, punctuation, and emoji all at once.
    /// 3. Rejoin with `-`, lowercase.
    /// 4. Fallback to `station-{uuid8}` when the name is all-non-alphanumeric
    ///    (empty / emoji-only) so the route is still valid.
    ///
    /// Collision handling is the ``StationManager``'s responsibility — this
    /// property only sees one station's name and can't know about siblings.
    public var slug: String {
        let transliterated = name.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let pieces = transliterated
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let kebab = pieces.joined(separator: "-").lowercased()
        if kebab.isEmpty {
            return "station-\(id.uuidString.prefix(8).lowercased())"
        }
        return kebab
    }
}
