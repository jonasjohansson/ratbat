import Foundation

/// On-disk persistence for ``TasteProfileSnapshot``. Mirrors the shape of
/// ``StationStore`` — a couple of static methods for read / write, no
/// instance state, no caching.
///
/// Default location is
/// `~/Library/Application Support/Ratbat/taste-profile.json`. Call sites
/// usually pass an explicit URL so tests can land their snapshots in a
/// temp file; production code should use ``defaultURL()``.
public enum TasteProfileStore {
    public enum Error: Swift.Error, Sendable {
        case noApplicationSupport
        case encode(String)
        case decode(String)
        case io(String)
    }

    /// Canonical on-disk location. Creates intermediate directories. The
    /// path is platform-scoped so macOS + iOS flavours share the same
    /// JSON when they run against the same Application Support container.
    public static func defaultURL() throws -> URL {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let base = urls.first else {
            throw Error.noApplicationSupport
        }
        let folder = base.appendingPathComponent("Ratbat", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("taste-profile.json")
    }

    /// Write the snapshot as pretty-printed JSON so the file is grep-able
    /// from a terminal (debugging + transparency — the user can peek at
    /// what Ratbat thinks their taste looks like).
    public static func save(_ snapshot: TasteProfileSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do { data = try encoder.encode(snapshot) }
        catch { throw Error.encode("\(error)") }
        do { try data.write(to: url, options: .atomic) }
        catch { throw Error.io("\(error)") }
    }

    /// Read a snapshot. Returns an empty snapshot if the file doesn't
    /// exist yet — fresh installs shouldn't have to special-case that.
    public static func load(from url: URL) throws -> TasteProfileSnapshot {
        if !FileManager.default.fileExists(atPath: url.path) {
            return TasteProfileSnapshot()
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw Error.io("\(error)") }
        do { return try JSONDecoder().decode(TasteProfileSnapshot.self, from: data) }
        catch { throw Error.decode("\(error)") }
    }
}
