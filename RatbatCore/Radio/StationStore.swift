import Foundation
import OSLog

/// On-disk persistence for the user's ``Station`` list, written next to the
/// user's music folder as a hidden dotfile (`.ratbat-stations.json`).
///
/// Mirrors ``CacheStore`` in shape: a versioned JSON envelope around the
/// `[Station]` array. The versioning gives us a single explicit failure
/// mode (``StationError/versionMismatch``) when the on-disk shape changes
/// incompatibly — callers treat that identically to "no file yet" and start
/// with an empty list.
///
/// Separate from ``CacheStore`` because the station list has a completely
/// different lifecycle: the library cache can be blown away and rebuilt by
/// a rescan without user input, but stations are user-authored and must be
/// preserved even across full library reindexes.
enum StationStore {
    /// Hidden (dot-prefix) filename so it doesn't clutter Finder for users
    /// without "show hidden files" on. Sits alongside `.ratbat-cache.json`.
    static let filename = ".ratbat-stations.json"

    /// Bump when the JSON shape changes incompatibly. An older file with a
    /// mismatched version throws ``StationError/versionMismatch`` and the
    /// caller treats that like "no saved stations".
    static let currentVersion = 1

    static let logger = Logger(
        subsystem: RatbatLog.subsystem,
        category: "station-store"
    )

    struct StationFile: Codable {
        let version: Int
        let stations: [Station]
    }

    enum StationError: Error {
        case versionMismatch
        /// The envelope itself was unreadable (missing version, wrong shape,
        /// not JSON). Distinct from per-station decode failures — those
        /// don't throw, they get logged and skipped so one bad entry can't
        /// nuke the user's entire station list.
        case corruptEnvelope
    }

    /// Read and decode the stations file. Throws if the file is missing,
    /// unreadable, or tagged with a version this build doesn't recognise —
    /// the manager catches any error and falls back to `[]`.
    ///
    /// Stations are decoded **one at a time** so a single un-decodable
    /// entry (e.g. a `.bandcamp` station authored on macOS, loaded by an
    /// iOS build sharing the same Google Drive file) doesn't silently wipe
    /// every other station. Skipped entries are logged at info.
    static func load(from root: URL) throws -> [Station] {
        let url = root.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)

        let envelope: Any
        do {
            envelope = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Not-JSON. Caller treats as "no file".
            throw error
        }

        guard let dict = envelope as? [String: Any],
              let version = dict["version"] as? Int else {
            throw StationError.corruptEnvelope
        }
        guard version == currentVersion else {
            throw StationError.versionMismatch
        }

        // `stations` missing / malformed → treat as empty list rather than
        // throwing, same resilience stance as per-entry failures.
        guard let rawStations = dict["stations"] as? [Any] else {
            return []
        }

        let decoder = JSONDecoder()
        var stations: [Station] = []
        for raw in rawStations {
            do {
                let reserialized = try JSONSerialization.data(withJSONObject: raw)
                let station = try decoder.decode(Station.self, from: reserialized)
                stations.append(station)
            } catch {
                // Per-entry fail-open. Known trigger: a macOS-authored file
                // containing a `.bandcamp` station, read by an iOS build
                // where that case doesn't exist. Before this change the
                // whole file decode threw and the caller wiped all
                // stations — now only the unreadable entry is dropped.
                logger.info("StationStore: skipped undecodable station — \(String(describing: error), privacy: .public)")
            }
        }
        return stations
    }

    /// Encode and write the stations list atomically so a crash mid-write
    /// can't leave a half-written file that fails to decode on next launch.
    static func save(_ stations: [Station], to root: URL) throws {
        let url = root.appendingPathComponent(filename)
        let file = StationFile(version: currentVersion, stations: stations)
        let data = try JSONEncoder().encode(file)
        try data.write(to: url, options: .atomic)
    }

    /// Remove the stations file if present; a no-op when it doesn't exist.
    /// Useful for tests and for a future "reset stations" action.
    static func delete(from root: URL) throws {
        let url = root.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
