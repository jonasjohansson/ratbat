#if os(macOS)
import Foundation
import SQLite3
import OSLog

/// `SQLITE_TRANSIENT` tells SQLite to copy bound string/blob bytes into
/// its own buffer instead of holding the caller's pointer. Without this,
/// a Swift `String` backing buffer can be freed between `sqlite3_bind_text`
/// and `sqlite3_step`, leaving SQLite reading into garbage. The symbol
/// from the C header is a cast of `-1` which isn't imported into Swift,
/// so we re-declare it here with the same representation.
private let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

/// SQLite-backed history of every track Ratbat has streamed out. Scoped
/// per station so dedup ("don't play the same thing twice on this
/// station") works correctly even when the same track appears on
/// multiple stations.
///
/// Lives at `~/Library/Application Support/Ratbat/history.db`. Schema is
/// versioned via `PRAGMA user_version` so we can migrate later without
/// data loss.
///
/// ## Concurrency
///
/// All SQLite access is actor-isolated, so the underlying `sqlite3*`
/// handle is only ever touched from a single task at a time. We therefore
/// don't need `SQLITE_SERIALIZED` thread mode — actor isolation is the
/// synchronization boundary. The `OpaquePointer` never leaves the actor.
public actor HistoryStore {
    public struct Entry: Identifiable, Sendable, Hashable {
        public let id: Int64            // rowid
        public let stationID: UUID
        public let artist: String
        public let title: String
        public let playedAt: Date
        public let sourceShowURL: URL?
        public let youtubeID: String?
        public var saved: Bool
        public var cachedPath: String?
    }

    public enum Error: Swift.Error, Sendable {
        case openFailed(String)
        case queryFailed(String)
    }

    // `OpaquePointer` is not `Sendable`, but the handle is only read from
    // `deinit` (to close) and from actor-isolated methods (for queries).
    // The init sets it before the actor can be referenced elsewhere.
    // Mark `nonisolated(unsafe)` so the deinit can reach it; all
    // query-time access still goes through actor-isolated methods, which
    // is where the synchronization matters.
    private nonisolated(unsafe) var db: OpaquePointer?
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "history")
    private let dbURL: URL

    /// Production: default app-support path.
    /// Tests: pass a temporary URL for isolation.
    public init(databaseURL: URL? = nil) throws {
        if let url = databaseURL {
            self.dbURL = url
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appendingPathComponent("Ratbat")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.dbURL = support.appendingPathComponent("history.db")
        }

        // Under Swift 6 strict concurrency an actor `init` is nonisolated
        // by default, so we can't `await`/call the actor-isolated helpers
        // here. Do the open + migration inline — `self` hasn't escaped
        // yet, so touching the DB handle here is safe.
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let handle { sqlite3_close(handle) }
            throw Error.openFailed(msg)
        }
        self.db = handle

        try Self.execRaw("PRAGMA journal_mode = WAL;", on: handle)
        try Self.execRaw("PRAGMA synchronous = NORMAL;", on: handle)
        try Self.execRaw("PRAGMA foreign_keys = ON;", on: handle)

        if Self.userVersion(on: handle) < 1 {
            try Self.migrateToV1(on: handle)
            try Self.execRaw("PRAGMA user_version = 1;", on: handle)
            logger.info("history.db migrated to v1 at \(self.dbURL.path, privacy: .public)")
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Dedup query: has this station already played a track with this
    /// (artist, title) pair? Match is case-insensitive on normalized
    /// strings.
    public func hasPlayed(station: UUID, artist: String, title: String) throws -> Bool {
        let sql = """
            SELECT 1 FROM history
            WHERE station_id = ? AND artist_norm = ? AND title_norm = ?
            LIMIT 1;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let stationStr = station.uuidString
        let artistN = Self.normalize(artist)
        let titleN = Self.normalize(title)

        sqlite3_bind_text(stmt, 1, stationStr, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, artistN, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, titleN, -1, SQLITE_TRANSIENT)

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw Error.queryFailed(lastError())
    }

    /// Record a new play. Returns the row id so caller can update the
    /// entry later (e.g. to mark saved).
    @discardableResult
    public func record(
        station: UUID,
        artist: String,
        title: String,
        playedAt: Date = Date(),
        sourceShowURL: URL? = nil,
        youtubeID: String? = nil,
        cachedPath: String? = nil
    ) throws -> Int64 {
        let sql = """
            INSERT INTO history
              (station_id, artist, title, artist_norm, title_norm,
               played_at, source_show_url, youtube_id, saved, cached_path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?);
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let stationStr = station.uuidString
        let artistN = Self.normalize(artist)
        let titleN = Self.normalize(title)

        sqlite3_bind_text(stmt, 1, stationStr, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, artist, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, artistN, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, titleN, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, playedAt.timeIntervalSince1970)

        if let sourceShowURL {
            sqlite3_bind_text(stmt, 7, sourceShowURL.absoluteString, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        if let youtubeID {
            sqlite3_bind_text(stmt, 8, youtubeID, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        if let cachedPath {
            sqlite3_bind_text(stmt, 9, cachedPath, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw Error.queryFailed(lastError())
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Mark an entry as saved (♥). `cachedPath` is the path where the
    /// audio file now lives (permanent, outside the disposable cache).
    public func markSaved(id: Int64, cachedPath: String) throws {
        let sql = """
            UPDATE history SET saved = 1, cached_path = ? WHERE id = ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, cachedPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw Error.queryFailed(lastError())
        }
    }

    /// Entries played today (midnight-to-now) that are NOT saved. Used
    /// by the daily cleanup job to know which cached files to delete.
    public func playedToday() throws -> [Entry] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let sql = """
            SELECT id, station_id, artist, title, played_at,
                   source_show_url, youtube_id, saved, cached_path
            FROM history
            WHERE played_at >= ? AND saved = 0
            ORDER BY played_at DESC;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, startOfToday.timeIntervalSince1970)
        return collectRows(stmt)
    }

    /// Entries for which `saved == false` and `cachedPath != nil`.
    /// These are candidates for the midnight sweep — cached but not
    /// permanently kept.
    public func unsavedCachedEntries() throws -> [Entry] {
        let sql = """
            SELECT id, station_id, artist, title, played_at,
                   source_show_url, youtube_id, saved, cached_path
            FROM history
            WHERE saved = 0 AND cached_path IS NOT NULL
            ORDER BY played_at DESC;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return collectRows(stmt)
    }

    /// All saved entries for a station, newest first. For reporting /
    /// "what did I like recently on this station".
    public func savedEntries(forStation station: UUID, limit: Int = 100) throws -> [Entry] {
        let sql = """
            SELECT id, station_id, artist, title, played_at,
                   source_show_url, youtube_id, saved, cached_path
            FROM history
            WHERE station_id = ? AND saved = 1
            ORDER BY played_at DESC
            LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        return collectRows(stmt)
    }

    // MARK: - Internals

    // Init-time helpers. Static so they can run from the nonisolated
    // `init` without tripping actor-isolation checks.

    private static func execRaw(_ sql: String, on handle: OpaquePointer) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
            if let err { sqlite3_free(err) }
            throw Error.queryFailed(msg)
        }
    }

    private static func userVersion(on handle: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func migrateToV1(on handle: OpaquePointer) throws {
        try execRaw("""
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                station_id TEXT NOT NULL,
                artist TEXT NOT NULL,
                title TEXT NOT NULL,
                artist_norm TEXT NOT NULL,
                title_norm TEXT NOT NULL,
                played_at REAL NOT NULL,
                source_show_url TEXT,
                youtube_id TEXT,
                saved INTEGER NOT NULL DEFAULT 0,
                cached_path TEXT
            );
            """, on: handle)
        try execRaw("""
            CREATE INDEX IF NOT EXISTS history_dedup
                ON history(station_id, artist_norm, title_norm);
            """, on: handle)
        try execRaw("""
            CREATE INDEX IF NOT EXISTS history_played_at
                ON history(played_at);
            """, on: handle)
        try execRaw("""
            CREATE INDEX IF NOT EXISTS history_saved
                ON history(saved, cached_path);
            """, on: handle)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else {
            throw Error.queryFailed(lastError())
        }
        return stmt
    }

    private func lastError() -> String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// Read all rows from a prepared SELECT whose columns match
    /// `(id, station_id, artist, title, played_at, source_show_url,
    /// youtube_id, saved, cached_path)` in that order.
    private func collectRows(_ stmt: OpaquePointer?) -> [Entry] {
        var out: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = row(from: stmt) {
                out.append(entry)
            }
        }
        return out
    }

    private func row(from stmt: OpaquePointer?) -> Entry? {
        guard let stmt else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        guard let stationCStr = sqlite3_column_text(stmt, 1) else { return nil }
        let stationStr = String(cString: stationCStr)
        guard let stationID = UUID(uuidString: stationStr) else { return nil }

        guard let artistCStr = sqlite3_column_text(stmt, 2) else { return nil }
        let artist = String(cString: artistCStr)

        guard let titleCStr = sqlite3_column_text(stmt, 3) else { return nil }
        let title = String(cString: titleCStr)

        let playedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))

        var sourceShowURL: URL?
        if sqlite3_column_type(stmt, 5) != SQLITE_NULL,
           let cStr = sqlite3_column_text(stmt, 5) {
            sourceShowURL = URL(string: String(cString: cStr))
        }

        var youtubeID: String?
        if sqlite3_column_type(stmt, 6) != SQLITE_NULL,
           let cStr = sqlite3_column_text(stmt, 6) {
            youtubeID = String(cString: cStr)
        }

        let saved = sqlite3_column_int64(stmt, 7) != 0

        var cachedPath: String?
        if sqlite3_column_type(stmt, 8) != SQLITE_NULL,
           let cStr = sqlite3_column_text(stmt, 8) {
            cachedPath = String(cString: cStr)
        }

        return Entry(
            id: id,
            stationID: stationID,
            artist: artist,
            title: title,
            playedAt: playedAt,
            sourceShowURL: sourceShowURL,
            youtubeID: youtubeID,
            saved: saved,
            cachedPath: cachedPath
        )
    }

    /// Normalize artist/title for dedup: lowercase + collapse whitespace.
    /// Preserves internal punctuation so "Drake's" is different from
    /// "Drakes".
    internal static func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
#endif
