import Foundation

/// A radio station the broadcaster can serve.
///
/// Five concrete kinds ship today:
/// - ``Kind/playlist(queue:)`` — a fixed queue derived from a user's
///   library ``Playlist``, reshuffled by ``PlaylistSource`` on each start.
/// - ``Kind/nts(config:)`` — a generative, NTS-backed station driven by
///   an ``NTSStationConfig`` (tags + optional year range).
/// - ``Kind/lastFM(config:)`` — a generative, Last.fm-backed station
///   driven by a ``LastFMStationConfig`` (tags + optional year range).
/// - ``Kind/bandcamp(config:)`` — a generative, Bandcamp-backed station
///   driven by a ``BandcampStationConfig`` (macOS-only; the scraping
///   client that powers it is Foundation-heavy and guarded out on iOS).
/// - ``Kind/libraryRadio(config:)`` — a self-seeding station over the
///   owner's own indexed library, driven by a
///   ``LibraryRadioStationConfig`` (taste-scored, owned tracks only).
///
/// The `Kind` enum is the source-of-truth for where tracks come from;
/// the old `seed: Seed` marker field has been retired. Convenience
/// accessors (``queue``, ``ntsConfig``, ``lastFMConfig``,
/// ``bandcampConfig``) let existing call sites that only care about one
/// variant keep working.
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
    /// as long as every associated payload is Codable — all four
    /// variants satisfy that (the `.bandcamp` case is macOS-only; on iOS
    /// the enum has only three variants, still all Codable).
    public enum Kind: Hashable, Sendable, Codable {
        /// Fixed queue of tracks. ``PlaylistSource`` shuffles it on every
        /// broadcast start (and after each full pass), so the order — and
        /// the opening track — varies from one start to the next.
        case playlist(queue: [Track])
        /// Generative NTS-backed station. Controller state (pool, history
        /// dedup, resolver) is reconstructed on each broadcast start from
        /// the config; the config itself is the persisted seed.
        case nts(config: NTSStationConfig)
        /// Generative Last.fm-backed station. Same lifecycle as NTS — the
        /// config is the only persisted seed; controller + pool rebuild on
        /// every broadcast start.
        case lastFM(config: LastFMStationConfig)
        #if os(macOS)
        /// Generative Bandcamp-backed station. macOS-only because the
        /// scraping client (``BandcampClient``) is Foundation-heavy and
        /// not compiled on iOS — the associated config references
        /// `BandcampClient.Sort` so this enum case has to follow the same
        /// platform gate. Same lifecycle as Last.fm / NTS: config is the
        /// persisted seed, controller + pool rebuild per broadcast start.
        case bandcamp(config: BandcampStationConfig)
        #endif
        /// Self-seeding station over the owner's own indexed library
        /// (signal-model design §4): the taste profile scores the pool,
        /// the facets filter it, and only owned files ever play. NOT
        /// platform-gated, deliberately — gating `.bandcamp` is what
        /// makes iOS builds drop macOS-authored entries from the shared
        /// stations file, and this kind's config is plain Foundation, so
        /// there is no reason to re-create that problem. (Broadcasting it
        /// is still macOS-only; iOS merely keeps the entry decodable.)
        case libraryRadio(config: LibraryRadioStationConfig)
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

    /// Last.fm config, or `nil` for non-Last.fm stations.
    public var lastFMConfig: LastFMStationConfig? {
        if case let .lastFM(c) = kind { return c }
        return nil
    }

    #if os(macOS)
    /// Bandcamp config, or `nil` for non-Bandcamp stations. macOS-only,
    /// mirroring the `.bandcamp` case's platform gate.
    public var bandcampConfig: BandcampStationConfig? {
        if case let .bandcamp(c) = kind { return c }
        return nil
    }
    #endif

    /// Library Radio config, or `nil` for other kinds. Cross-platform,
    /// like the case it mirrors.
    public var libraryRadioConfig: LibraryRadioStationConfig? {
        if case let .libraryRadio(c) = kind { return c }
        return nil
    }

    // MARK: - Factories

    /// Build a station seeded from a playlist. Auto-names as
    /// "Radio based on {playlist name}" so the sidebar immediately reads
    /// as what the user just did. The queue is stored in natural playlist
    /// order; ``PlaylistSource`` shuffles it on every broadcast start, so
    /// there's no need to freeze a single shuffle here.
    public static func from(playlist: Playlist) -> Station {
        Station(
            name: "Radio based on \(playlist.name)",
            kind: .playlist(queue: playlist.tracks)
        )
    }

    /// Build a station from an ``NTSStationConfig``. Reuses the config's
    /// `id` as the station id so ``HistoryStore`` dedup keys stay stable
    /// across broadcaster restarts.
    public static func fromNTS(_ config: NTSStationConfig) -> Station {
        Station(id: config.id, name: config.name, kind: .nts(config: config))
    }

    /// Build a station from a ``LastFMStationConfig``. Reuses the config's
    /// `id` as the station id for history-dedup stability, same as NTS.
    public static func fromLastFM(_ config: LastFMStationConfig) -> Station {
        Station(id: config.id, name: config.name, kind: .lastFM(config: config))
    }

    #if os(macOS)
    /// Build a station from a ``BandcampStationConfig``. Reuses the
    /// config's `id` for history-dedup stability, same as NTS / Last.fm.
    /// macOS-only to match ``Kind/bandcamp(config:)``'s gate.
    public static func fromBandcamp(_ config: BandcampStationConfig) -> Station {
        Station(id: config.id, name: config.name, kind: .bandcamp(config: config))
    }
    #endif

    /// Build a station from a ``LibraryRadioStationConfig``. Reuses the
    /// config's `id` as the station id — the invariant every kind keeps
    /// so ``HistoryStore`` dedup, skips, saves and taste affinity stay
    /// attached across restarts and edits.
    public static func fromLibraryRadio(_ config: LibraryRadioStationConfig) -> Station {
        Station(id: config.id, name: config.name, kind: .libraryRadio(config: config))
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
