import Foundation

/// On-disk cache for a library scan, written next to the user's music folder
/// as a hidden dotfile (`.johanssound-cache.json`) so a subsequent launch can
/// skip the full metadata sweep and show the library instantly.
///
/// Format is deliberately trivial: a versioned JSON envelope around the same
/// ``Playlist`` values the indexer would produce. No partial updates, no
/// per-file mtime tracking — v1 is "load if it exists and version matches,
/// otherwise do a full scan and overwrite." The cost of a full rescan is the
/// price for not having invalidation yet.
///
/// `version` bumps whenever the on-disk shape changes in a way older readers
/// can't cope with (new required fields, removed fields, enum cases). When
/// that happens, old caches fail to decode → caller falls through to a fresh
/// scan and the cache is replaced.
enum CacheStore {
    /// Hidden (dot-prefix) filename so the cache doesn't show up in Finder
    /// for users who aren't opted into "show hidden files".
    static let cacheFilename = ".johanssound-cache.json"

    /// Bump when the JSON shape changes incompatibly. Decoding a cache with
    /// a different version throws ``CacheError/versionMismatch`` and callers
    /// treat that like "no cache."
    static let currentVersion = 1

    struct CacheFile: Codable {
        let version: Int
        let playlists: [Playlist]
    }

    enum CacheError: Error {
        case versionMismatch
    }

    /// Read and decode the cache file sitting at `{root}/.johanssound-cache.json`.
    /// Throws if the file is missing, unreadable, corrupt, or tagged with a
    /// version this build doesn't recognise.
    static func load(for root: URL) throws -> [Playlist] {
        let url = root.appendingPathComponent(cacheFilename)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(CacheFile.self, from: data)
        guard decoded.version == currentVersion else {
            throw CacheError.versionMismatch
        }
        return decoded.playlists
    }

    /// Encode and write the cache atomically so a crash mid-write can't leave
    /// a half-written file that fails to decode on the next launch.
    static func save(_ playlists: [Playlist], for root: URL) throws {
        let url = root.appendingPathComponent(cacheFilename)
        let file = CacheFile(version: currentVersion, playlists: playlists)
        let data = try JSONEncoder().encode(file)
        try data.write(to: url, options: .atomic)
    }

    /// Remove the cache file if present; a no-op when it doesn't exist. Used
    /// by the "rescan" path so the next `load` is forced to re-index.
    static func delete(for root: URL) throws {
        let url = root.appendingPathComponent(cacheFilename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
