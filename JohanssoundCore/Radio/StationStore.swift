import Foundation

/// On-disk persistence for the user's ``Station`` list, written next to the
/// user's music folder as a hidden dotfile (`.johanssound-stations.json`).
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
    /// without "show hidden files" on. Sits alongside `.johanssound-cache.json`.
    static let filename = ".johanssound-stations.json"

    /// Bump when the JSON shape changes incompatibly. An older file with a
    /// mismatched version throws ``StationError/versionMismatch`` and the
    /// caller treats that like "no saved stations".
    static let currentVersion = 1

    struct StationFile: Codable {
        let version: Int
        let stations: [Station]
    }

    enum StationError: Error {
        case versionMismatch
    }

    /// Read and decode the stations file. Throws if the file is missing,
    /// unreadable, corrupt, or tagged with a version this build doesn't
    /// recognise — the manager catches any error and falls back to `[]`.
    static func load(from root: URL) throws -> [Station] {
        let url = root.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(StationFile.self, from: data)
        guard decoded.version == currentVersion else {
            throw StationError.versionMismatch
        }
        return decoded.stations
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
