import Foundation
import SwiftUI

/// Unified sidebar selection — the sidebar now holds both playlists (the
/// library) and stations, so a plain `Playlist.ID?` no longer spans the
/// full selection space. Kept a flat sum type so `List(selection:)` can use
/// it directly; `Hashable` is the only requirement SwiftUI imposes.
public enum SidebarSelection: Hashable, Sendable {
    case playlist(Playlist.ID)
    case station(Station.ID)
}

/// Owns the user's saved list of stations.
///
/// Task 3.5 expanded this from "one active station" to a full list: each
/// station persists across launches in `{musicFolder}/.ratbat-stations.json`
/// (see ``StationStore``), is addressable by URL slug, and can be renamed
/// or deleted independently. Broadcasting lives on ``RadioBroadcaster`` —
/// this type only cares about the station catalogue.
///
/// `@MainActor` because it publishes UI state and is read straight from
/// SwiftUI views via `@ObservedObject`. Mutations save synchronously in
/// the same tick so a crash right after a rename/delete can't leave the
/// disk state stale.
@MainActor
public final class StationManager: ObservableObject {
    /// All user-authored stations, in creation order. Order is stable so
    /// the sidebar doesn't jitter after a rename.
    @Published public private(set) var stations: [Station] = []

    /// Where ``StationStore`` writes the persistence file. `nil` until the
    /// user has picked a music folder — before that, creates/renames still
    /// update the in-memory list but disk I/O is skipped.
    private var storageRoot: URL?

    /// Fired whenever a mutation changes a station's computed ``Station/slug``
    /// (old slug first, new slug second). Slugs key state that lives *outside*
    /// the catalogue — notably ``BroadcastPreferences``'s auto-start list —
    /// and that state has no other way to learn a slug moved: preferences
    /// are per-machine `UserDefaults` while stations sync across machines
    /// via the shared drive, so nothing else observes both stores. Wired
    /// once in `RootView`; a closure rather than Combine because there is
    /// exactly one interested party and no UI to drive.
    public var slugDidChange: ((_ old: String, _ new: String) -> Void)?

    /// Fired when ``delete(_:)`` removes a station, with the slug it held.
    /// The delete counterpart to ``slugDidChange``: without it, deleting a
    /// station orphans its slug in the auto-start / last-live lists, and a
    /// later station created with the same name silently inherits both
    /// (review G3). Same wiring site and rationale as ``slugDidChange``.
    public var slugWasDeleted: ((_ slug: String) -> Void)?

    public init() {}

    // MARK: - Storage

    /// Point the manager at the music folder and load any stations
    /// already on disk. Safe to call multiple times (e.g. if the user
    /// picks a new folder mid-session) — the existing list is replaced
    /// atomically with whatever the new folder holds.
    public func setStorage(root: URL) {
        storageRoot = root
        do {
            stations = try StationStore.load(from: root)
        } catch {
            // Missing file, version mismatch, or corrupt JSON — all three
            // collapse to "no saved stations" and we start empty. A fresh
            // write on the next mutation will overwrite any bad file.
            stations = []
        }
    }

    /// Persist the current list. Silently swallows errors: a failed write
    /// shouldn't crash the UI, and OSLog captures the details for debugging.
    private func persist() {
        guard let root = storageRoot else { return }
        try? StationStore.save(stations, to: root)
    }

    // MARK: - CRUD

    /// Create a station seeded from `playlist`, append it to the list,
    /// and return it so the caller can immediately select / start it.
    /// Collision-safe: if the auto-generated slug clashes with an
    /// existing station, we bump the station's *name* with a suffix
    /// (e.g. "Radio based on Jazz (2)") so the slug derivation yields a
    /// unique value without special-casing slug handling elsewhere.
    @discardableResult
    public func create(from playlist: Playlist) -> Station {
        var station = Station.from(playlist: playlist)
        station.name = uniquifyName(station.name)
        stations.append(station)
        persist()
        return station
    }

    /// Rename a station in place. No-op if the id isn't found or the new
    /// name is empty after trimming. If the new name would collide on slug
    /// with another station, bumps it with a `(2)`-style suffix just like
    /// ``create(from:)``.
    ///
    /// Fires ``slugDidChange`` when the rename moves the computed slug —
    /// and only then: a rename that keeps the slug (punctuation-only edits
    /// collapse in the derivation) leaves slug-keyed state valid as-is.
    public func rename(_ id: Station.ID, to newName: String) {
        guard let index = stations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let unique = uniquifyName(trimmed, ignoring: id)
        guard stations[index].name != unique else { return }
        let oldSlug = stations[index].slug
        stations[index].name = unique
        persist()
        let newSlug = stations[index].slug
        if oldSlug != newSlug {
            slugDidChange?(oldSlug, newSlug)
        }
    }

    /// Replace a generative station's faceted query, in place.
    ///
    /// The station keeps its `id`, and so does its config — which matters
    /// more than it looks: the config id is the key ``HistoryStore`` uses
    /// for per-station dedup, skips, saves and taste affinity. Before this
    /// existed, "same station, different genres" meant delete + recreate,
    /// which minted a fresh UUID and left every play the station had ever
    /// recorded pointing at a station that no longer exists.
    ///
    /// The pool is not rebuilt here. ``StationManager`` owns the catalogue,
    /// not the broadcast; a live station picks the new facets up when its
    /// pipeline is rebuilt — see ``RadioBroadcaster/restartBroadcast(station:)``,
    /// which the caller invokes deliberately so the restart is never a
    /// surprise mid-track.
    ///
    /// Returns the updated station, or `nil` when the id is unknown or the
    /// station is playlist-backed — a fixed queue has no query to edit, and
    /// answering `nil` says so instead of looking like a successful no-op.
    @discardableResult
    public func updateQuery(_ id: Station.ID, to query: FacetedQuery) -> Station? {
        guard let index = stations.firstIndex(where: { $0.id == id }) else { return nil }
        switch stations[index].kind {
        case .playlist:
            return nil
        case .nts(var config):
            config.query = query
            stations[index].kind = .nts(config: config)
        case .lastFM(var config):
            config.query = query
            stations[index].kind = .lastFM(config: config)
        #if os(macOS)
        case .bandcamp(var config):
            config.query = query
            stations[index].kind = .bandcamp(config: config)
        #endif
        case .libraryRadio(var config):
            config.query = Self.normalizedLibraryRadioQuery(query)
            stations[index].kind = .libraryRadio(config: config)
        }
        persist()
        return stations[index]
    }

    #if os(macOS)
    /// Change a Bandcamp station's sort dimension in place.
    ///
    /// Lives outside ``updateQuery(_:to:)`` because `sort` isn't part of
    /// the shared ``FacetedQuery`` — it's the one knob only Bandcamp has.
    /// It's editable for the same reason the query is: the add sheet
    /// offers it, so editing shouldn't be able to do less than creating.
    ///
    /// Returns `nil` for an unknown id or a non-Bandcamp station.
    @discardableResult
    public func updateBandcampSort(
        _ id: Station.ID, to sort: BandcampClient.Sort
    ) -> Station? {
        guard let index = stations.firstIndex(where: { $0.id == id }),
              case .bandcamp(var config) = stations[index].kind else { return nil }
        config.sort = sort
        stations[index].kind = .bandcamp(config: config)
        persist()
        return stations[index]
    }
    #endif

    /// Change a Last.fm station's Comfort ↔ Explore dial in place.
    ///
    /// Lives outside ``updateQuery(_:to:)`` for the same reason
    /// ``updateBandcampSort(_:to:)`` does: exploration isn't part of the
    /// shared ``FacetedQuery`` — it's the one knob only Last.fm has. An
    /// interim seam until the general `applyUpdate` lands with the web
    /// CRUD API; the edit sheet needs *some* setter so editing can't do
    /// less than creating.
    ///
    /// The value is clamped to `[0, 1]` via
    /// ``LastFMStationConfig/clampExploration(_:)`` — the config's `var`
    /// bypasses its init, so the clamp must be applied here. Station and
    /// config ids are preserved (the config id keys ``HistoryStore``
    /// dedup and taste affinity, same invariant as ``updateQuery(_:to:)``).
    ///
    /// Returns `nil` for an unknown id or a non-Last.fm station.
    @discardableResult
    public func updateExploration(_ id: Station.ID, to exploration: Double) -> Station? {
        guard let index = stations.firstIndex(where: { $0.id == id }),
              case .lastFM(var config) = stations[index].kind else { return nil }
        config.exploration = LastFMStationConfig.clampExploration(exploration)
        stations[index].kind = .lastFM(config: config)
        persist()
        return stations[index]
    }

    /// Remove a station. No-op if the id isn't found. Fires
    /// ``slugWasDeleted`` with the removed station's slug so slug-keyed
    /// state elsewhere (auto-start, last-live) can forget it.
    public func delete(_ id: Station.ID) {
        guard let index = stations.firstIndex(where: { $0.id == id }) else { return }
        let slug = stations[index].slug
        stations.remove(at: index)
        persist()
        slugWasDeleted?(slug)
    }

    /// Create a new NTS-backed station from a config and persist immediately.
    /// Collision-safe on `name`: the NTS creation UI doesn't build its name
    /// from a sibling object (the way ``create(from:)`` leans on playlist
    /// names), so a bare `(2)`-style suffix is appended if the user picks a
    /// name that's already taken.
    @discardableResult
    public func createNTS(_ config: NTSStationConfig) -> Station {
        var cfg = config
        cfg.name = uniquifyName(cfg.name)
        let station = Station.fromNTS(cfg)
        stations.append(station)
        persist()
        return station
    }

    /// Create a new Last.fm-backed station from a config and persist
    /// immediately. Same collision-handling as ``createNTS(_:)``.
    @discardableResult
    public func createLastFM(_ config: LastFMStationConfig) -> Station {
        var cfg = config
        cfg.name = uniquifyName(cfg.name)
        let station = Station.fromLastFM(cfg)
        stations.append(station)
        persist()
        return station
    }

    #if os(macOS)
    /// Create a new Bandcamp-backed station from a config and persist
    /// immediately. Same collision-handling as ``createNTS(_:)``.
    /// macOS-only because ``BandcampStationConfig`` is gated behind the
    /// same platform check.
    @discardableResult
    public func createBandcamp(_ config: BandcampStationConfig) -> Station {
        var cfg = config
        cfg.name = uniquifyName(cfg.name)
        let station = Station.fromBandcamp(cfg)
        stations.append(station)
        persist()
        return station
    }
    #endif

    /// Create a new Library Radio station from a config and persist
    /// immediately. Same collision-handling as ``createNTS(_:)``.
    /// Cross-platform because the config is — see the `.libraryRadio`
    /// case's note on why this kind avoids the `.bandcamp` gate.
    @discardableResult
    public func createLibraryRadio(_ config: LibraryRadioStationConfig) -> Station {
        var cfg = config
        cfg.name = uniquifyName(cfg.name)
        let station = Station.fromLibraryRadio(cfg)
        stations.append(station)
        persist()
        return station
    }

    /// Find a station whose ``Station/slug`` matches `slug`. Used by the
    /// HTTP router to map an incoming `/stream/{slug}.aac` request to a
    /// specific station's broadcast pipeline.
    public func station(forSlug slug: String) -> Station? {
        stations.first(where: { $0.slug == slug })
    }

    /// Find a station by id. The id-keyed sibling of
    /// ``station(forSlug:)`` — the web control plane addresses stations
    /// by UUID (the identifier that survives renames), not by slug.
    public func station(id: Station.ID) -> Station? {
        stations.first(where: { $0.id == id })
    }

    // MARK: - Validated editing

    /// Why a create or edit was refused. Thrown (rather than the `nil`
    /// the older setters return) because the web has to answer with a
    /// *reason* — "no tags" and "no such station" are different HTTP
    /// statuses, and a `nil` can't carry the distinction.
    public enum StationEditError: Error, Equatable {
        /// The id resolved to nothing — deleted, or never existed here.
        case unknownStation
        /// A playlist station was asked to change its query or pool
        /// behavior. A fixed queue has neither.
        case kindHasNoQuery
        /// Every generative station needs at least one genre tag — the
        /// rule the SwiftUI Add sheets used to gate in `canSubmit`,
        /// moved down here so the web can't create what the desktop
        /// couldn't.
        case emptyGenreTags
        /// A name was supplied but trims to nothing. Distinct from *no*
        /// name, which falls back to ``FacetedQuery/suggestedName``.
        case emptyName
        /// A knob was aimed at a kind that doesn't have it — sort on a
        /// non-Bandcamp station, exploration on a non-Last.fm one.
        case wrongKind
    }

    /// The single validated creation surface for generative stations —
    /// the Add sheets and the web `/stations/create` route both land
    /// here, so the two can never drift on what a valid station is.
    ///
    /// `name` is optional: `nil` (or the sheets' empty field) falls back
    /// to the query's ``FacetedQuery/suggestedName``, and either way the
    /// final name gets the same `(2)`-style collision bump the older
    /// creators apply. A *provided* name that trims to nothing is an
    /// error rather than a silent fallback — the caller typed something,
    /// and "we ignored it" is worse than "it was empty".
    @discardableResult
    public func createStation(_ draft: StationDraft, name: String?) throws -> Station {
        // Library Radio is the one kind allowed to carry zero tags —
        // "no filter" legitimately means "the whole library" there,
        // whereas a generative station with no tags has nothing to fetch.
        let isLibraryRadio: Bool = {
            if case .libraryRadio = draft { return true }
            return false
        }()
        guard isLibraryRadio || !draft.query.genreTags.isEmpty else {
            throw StationEditError.emptyGenreTags
        }
        let finalName: String
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw StationEditError.emptyName }
            finalName = trimmed
        } else if isLibraryRadio, draft.query.genreTags.isEmpty {
            // suggestedName says "New Station" for an empty query; this
            // kind has a truthful name for that state.
            finalName = "Library Radio"
        } else {
            finalName = draft.query.suggestedName
        }
        switch draft {
        case .nts(let query, let shufflePool):
            return createNTS(NTSStationConfig(
                name: finalName, query: query, shufflePool: shufflePool
            ))
        case .lastFM(let query, let shufflePool, let exploration):
            return createLastFM(LastFMStationConfig(
                name: finalName, query: query,
                shufflePool: shufflePool, exploration: exploration
            ))
        #if os(macOS)
        case .bandcamp(let query, let sort, let shufflePool):
            return createBandcamp(BandcampStationConfig(
                name: finalName, query: query,
                sort: sort, shufflePool: shufflePool
            ))
        #endif
        case .libraryRadio(let query, let shufflePool):
            return createLibraryRadio(LibraryRadioStationConfig(
                name: finalName,
                query: Self.normalizedLibraryRadioQuery(query),
                shufflePool: shufflePool
            ))
        }
    }

    /// Every candidate on a Library Radio station is owned by
    /// definition, so a persisted `excludeOwnedLibrary: true` would be a
    /// station configured to play nothing. The server-side contract says
    /// the flag is ignored/normalized for this kind — normalized HERE,
    /// at the single write surface, so the stored config never carries
    /// the contradiction in the first place.
    private static func normalizedLibraryRadioQuery(_ query: FacetedQuery) -> FacetedQuery {
        var normalized = query
        normalized.excludeOwnedLibrary = false
        return normalized
    }

    /// Apply a sparse edit — every non-nil field of `update` — as one
    /// atomic mutation with a single persist. The general successor to
    /// the per-knob setters above (``updateQuery(_:to:)``,
    /// ``updateBandcampSort(_:to:)``, ``updateExploration(_:to:)``):
    /// the desktop edit sheet and the web `/stations/update` route both
    /// save through here, so one edit is one disk write and one
    /// `@Published` tick, however many knobs it turns.
    ///
    /// The station keeps its `id` and so does its config — the config id
    /// keys ``HistoryStore`` dedup, skips, saves and taste affinity, so
    /// letting it move would orphan everything the station ever played
    /// (the delete-and-recreate bug this API exists to prevent).
    ///
    /// Validation happens before any mutation: an update either applies
    /// whole or leaves the station exactly as it was. A rename rides the
    /// same trimmed/uniquify logic as ``rename(_:to:)`` and fires
    /// ``slugDidChange`` when the computed slug moves.
    ///
    /// The pool is not rebuilt here — same division of labour as
    /// ``updateQuery(_:to:)``: the caller restarts the broadcast
    /// deliberately, or doesn't.
    @discardableResult
    public func applyUpdate(_ id: Station.ID, _ update: StationUpdate) throws -> Station {
        guard let index = stations.firstIndex(where: { $0.id == id }) else {
            throw StationEditError.unknownStation
        }
        let isPlaylist: Bool = {
            if case .playlist = stations[index].kind { return true }
            return false
        }()
        let isLibraryRadio: Bool = {
            if case .libraryRadio = stations[index].kind { return true }
            return false
        }()
        if let query = update.query {
            guard !isPlaylist else { throw StationEditError.kindHasNoQuery }
            // Same carve-out as ``createStation(_:name:)``: an empty tag
            // list is a legal "whole library" filter for Library Radio
            // and an error everywhere else.
            guard isLibraryRadio || !query.genreTags.isEmpty else {
                throw StationEditError.emptyGenreTags
            }
        }
        if update.shufflePool != nil, isPlaylist {
            throw StationEditError.wrongKind
        }
        #if os(macOS)
        if update.sort != nil {
            guard case .bandcamp = stations[index].kind else {
                throw StationEditError.wrongKind
            }
        }
        #endif
        if update.exploration != nil {
            guard case .lastFM = stations[index].kind else {
                throw StationEditError.wrongKind
            }
        }
        var trimmedName: String?
        if let name = update.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw StationEditError.emptyName }
            trimmedName = trimmed
        }

        // Validation is done — from here the update applies in full.
        let oldSlug = stations[index].slug
        if let trimmedName {
            stations[index].name = uniquifyName(trimmedName, ignoring: id)
        }
        switch stations[index].kind {
        case .playlist:
            break
        case .nts(var config):
            if let query = update.query { config.query = query }
            if let shuffle = update.shufflePool { config.shufflePool = shuffle }
            stations[index].kind = .nts(config: config)
        case .lastFM(var config):
            if let query = update.query { config.query = query }
            if let shuffle = update.shufflePool { config.shufflePool = shuffle }
            if let exploration = update.exploration {
                // The config's `var` bypasses its clamping init, so clamp
                // here — same rule as ``updateExploration(_:to:)``.
                config.exploration = LastFMStationConfig.clampExploration(exploration)
            }
            stations[index].kind = .lastFM(config: config)
        #if os(macOS)
        case .bandcamp(var config):
            if let query = update.query { config.query = query }
            if let shuffle = update.shufflePool { config.shufflePool = shuffle }
            if let sort = update.sort { config.sort = sort }
            stations[index].kind = .bandcamp(config: config)
        #endif
        case .libraryRadio(var config):
            if let query = update.query {
                config.query = Self.normalizedLibraryRadioQuery(query)
            }
            if let shuffle = update.shufflePool { config.shufflePool = shuffle }
            stations[index].kind = .libraryRadio(config: config)
        }
        persist()
        let newSlug = stations[index].slug
        if oldSlug != newSlug {
            slugDidChange?(oldSlug, newSlug)
        }
        return stations[index]
    }

    // MARK: - Slug collision handling

    /// Nudge `candidate` into a name whose ``Station/slug`` is unique among
    /// the current list (optionally ignoring `ignoring`, so rename doesn't
    /// collide with itself). Appends " (2)", " (3)", … until a free slot
    /// is found. The visible name carries the disambiguator; the derived
    /// slug follows naturally.
    private func uniquifyName(_ candidate: String, ignoring: Station.ID? = nil) -> String {
        var current = candidate
        var n = 2
        while slugIsTaken(for: current, ignoring: ignoring) {
            current = "\(candidate) (\(n))"
            n += 1
        }
        return current
    }

    private func slugIsTaken(for name: String, ignoring: Station.ID?) -> Bool {
        // Build a throwaway station just to compute the candidate slug —
        // cheaper than duplicating the slug algorithm here. Kind doesn't
        // affect the slug derivation; an empty playlist queue is fine.
        let probe = Station(id: UUID(), name: name, kind: .playlist(queue: []))
        let candidate = probe.slug
        return stations.contains { station in
            if station.id == ignoring { return false }
            return station.slug == candidate
        }
    }
}
