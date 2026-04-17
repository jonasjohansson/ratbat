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
    public func rename(_ id: Station.ID, to newName: String) {
        guard let index = stations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let unique = uniquifyName(trimmed, ignoring: id)
        guard stations[index].name != unique else { return }
        stations[index].name = unique
        persist()
    }

    /// Remove a station. No-op if the id isn't found.
    public func delete(_ id: Station.ID) {
        guard let index = stations.firstIndex(where: { $0.id == id }) else { return }
        stations.remove(at: index)
        persist()
    }

    /// Find a station whose ``Station/slug`` matches `slug`. Used by the
    /// HTTP router to map an incoming `/stream/{slug}.aac` request to a
    /// specific station's broadcast pipeline.
    public func station(forSlug slug: String) -> Station? {
        stations.first(where: { $0.slug == slug })
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
        // cheaper than duplicating the slug algorithm here.
        let probe = Station(id: UUID(), name: name, seed: .manual, queue: [])
        let candidate = probe.slug
        return stations.contains { station in
            if station.id == ignoring { return false }
            return station.slug == candidate
        }
    }
}
