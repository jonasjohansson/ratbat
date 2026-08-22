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

    /// One audited decision by the selection filter: a candidate that the
    /// mix-set rule dropped (or would have dropped, when the toggle is off).
    /// The log exists so the rule can be diagnosed — "why did the station
    /// get quieter?" has to be answerable without re-running the pipeline.
    public struct Exclusion: Sendable, Hashable, Identifiable {
        public let id: Int64            // rowid
        public let stationID: UUID
        public let artist: String
        public let title: String
        /// `nil` when the source gave no duration at all (NTS, Last.fm).
        /// Distinct from `0`, which would claim a zero-length track.
        public let durationSeconds: Double?
        /// Where the duration came from, e.g. `listing-featured-track`,
        /// `library`. `nil` alongside a `nil` duration.
        public let durationSource: String?
        /// Which arm of the rule fired: `duration` or `title`.
        public let arm: String
        /// The literal marker that fired, for the title arm.
        public let matchedText: String?
        /// `bandcamp` | `nts` | `lastfm` | `playlist` | `library`.
        public let sourceKind: String
        public let sourceURL: URL?
        /// The most recent sighting's state: `true` = actually dropped,
        /// `false` = shadow-logged because the toggle was off.
        public let enforced: Bool
        /// `true` if ANY sighting actually dropped this candidate. Read
        /// this, not `enforced`, to answer "did we ever lose it?".
        public let everEnforced: Bool
        /// How many of the sightings actually dropped the candidate.
        public let enforcedCount: Int
        /// Total sightings, enforced or shadow.
        public let hitCount: Int
        public let firstExcludedAt: Date
        public let lastExcludedAt: Date
    }

    /// Write side of ``Exclusion``: what the filter knows at decision time.
    /// The store stamps `id` and the timestamps, and maintains the counters.
    public struct ExclusionInput: Sendable, Hashable {
        public let artist: String
        public let title: String
        public let durationSeconds: Double?
        public let durationSource: String?
        public let arm: String
        public let matchedText: String?
        public let sourceKind: String
        public let sourceURL: URL?
        public let enforced: Bool

        public init(
            artist: String,
            title: String,
            durationSeconds: Double?,
            durationSource: String?,
            arm: String,
            matchedText: String?,
            sourceKind: String,
            sourceURL: URL?,
            enforced: Bool
        ) {
            self.artist = artist
            self.title = title
            self.durationSeconds = durationSeconds
            self.durationSource = durationSource
            self.arm = arm
            self.matchedText = matchedText
            self.sourceKind = sourceKind
            self.sourceURL = sourceURL
            self.enforced = enforced
        }
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
    private let logger = Logger(subsystem: RatbatLog.subsystem, category: "history")
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

        // Each step is atomic with its own version bump, and every step is
        // replayable, so an interrupted migration is recoverable rather
        // than terminal. `.notice`, not `.info`, so a migration that ran
        // is still visible in the log tomorrow.
        for (version, step) in Self.migrations {
            guard Self.userVersion(on: handle) < version else { continue }
            try Self.migrationStep(to: version, on: handle, step)
            logger.notice(
                "history.db migrated to v\(version, privacy: .public) at \(self.dbURL.path, privacy: .public)"
            )
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

    /// Single entry by rowid — the broadcaster resolves a playing track's
    /// provenance (YouTube id, source show/release URL) from its history
    /// row once per track change, for /now.json.
    public func entry(id: Int64) throws -> Entry? {
        let sql = """
            SELECT id, station_id, artist, title, played_at,
                   source_show_url, youtube_id, saved, cached_path
            FROM history
            WHERE id = ?
            LIMIT 1;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        return collectRows(stmt).first
    }

    // MARK: - v2: skip / play-count API (taste intelligence)

    /// Mark an entry as explicitly skipped. The station-scoped blacklist
    /// lookup (``hasSkipped(station:artist:)``) reads this to suppress any
    /// future pool candidates from the same artist.
    public func markSkipped(id: Int64) throws {
        let sql = "UPDATE history SET skipped = 1, skipped_at = ? WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Error.queryFailed(lastError())
        }
    }

    /// Has this artist been skipped on this station? Station-scoped so a
    /// skip on a jazz station doesn't suppress the same artist on a
    /// different ambient station. Normalized artist match, case-insensitive.
    public func hasSkipped(station: UUID, artist: String) throws -> Bool {
        let sql = """
            SELECT 1 FROM history
            WHERE station_id = ? AND artist_norm = ? AND skipped = 1
            LIMIT 1;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, Self.normalize(artist), -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw Error.queryFailed(lastError())
    }

    /// Every entry for a station where the user hit 👎. Newest-skipped
    /// first. Used by the transparency UI and by scoring.
    public func skippedEntries(forStation station: UUID, limit: Int = 200) throws -> [Entry] {
        let sql = """
            SELECT id, station_id, artist, title, played_at,
                   source_show_url, youtube_id, saved, cached_path
            FROM history
            WHERE station_id = ? AND skipped = 1
            ORDER BY skipped_at DESC
            LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        return collectRows(stmt)
    }

    /// Increment the play-through counter for `id`. Call this when a track
    /// finishes naturally (decoder hits EOF without the user skipping) so
    /// the taste profile can weight repeat-play artists over one-offs.
    public func incrementPlayCount(id: Int64) throws {
        let sql = "UPDATE history SET play_count = play_count + 1 WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Error.queryFailed(lastError())
        }
    }

    /// Total full play-throughs recorded for `artist` on this station —
    /// the sum of `play_count` across the artist's rows. Station-scoped to
    /// match the rest of the behavioral signals, and case-insensitive on
    /// the normalized artist. `0` when the artist has never played through.
    public func playThroughCount(forStation station: UUID, artist: String) throws -> Int {
        let sql = """
            SELECT COALESCE(SUM(play_count), 0) FROM history
            WHERE station_id = ? AND artist_norm = ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, Self.normalize(artist), -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
        if rc == SQLITE_DONE { return 0 }
        throw Error.queryFailed(lastError())
    }

    /// Recency-weighted play-through signal for `artist` on this station.
    /// Like ``playThroughCount(forStation:artist:)`` but each row's
    /// `play_count` is multiplied by an exponential decay of its age, so a
    /// track enjoyed last week pulls far harder than one from months ago.
    /// `halfLifeDays` is the age at which a play's weight halves (30d =
    /// noticeable mood drift). Computed in Swift rather than SQL so we
    /// don't depend on SQLite being built with the math extension.
    ///
    /// Note: `play_count` accumulates on the row created at the track's
    /// first play, so `played_at` is the *first*-play time — an
    /// approximation of when the listens happened, but the strongest
    /// recency anchor the schema records. `now` is injectable for tests.
    public func playThroughRecencyWeight(
        forStation station: UUID,
        artist: String,
        halfLifeDays: Double,
        now: Date = Date()
    ) throws -> Double {
        let sql = """
            SELECT play_count, played_at FROM history
            WHERE station_id = ? AND artist_norm = ? AND play_count > 0;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, Self.normalize(artist), -1, SQLITE_TRANSIENT)

        let nowEpoch = now.timeIntervalSince1970
        let halfLifeSeconds = max(halfLifeDays, 0.0001) * 86_400
        var weighted = 0.0
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let plays = Double(sqlite3_column_int64(stmt, 0))
                let playedAt = sqlite3_column_double(stmt, 1)
                let ageSeconds = max(0, nowEpoch - playedAt)
                let decay = pow(0.5, ageSeconds / halfLifeSeconds)
                weighted += plays * decay
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw Error.queryFailed(lastError())
            }
        }
        return weighted
    }

    /// Artists the user engages with most on this station, ranked by a
    /// blend of ♥-saves (weighted heavier) and full play-throughs. These
    /// are the seeds for similar-artist discovery — "find more like the
    /// ones I love here." Returns distinct artist display names, strongest
    /// affinity first; artists with no positive signal are excluded.
    public func topAffinityArtists(forStation station: UUID, limit: Int = 5) throws -> [String] {
        // Boost dominates (10) over save (3) over play-through (1): a
        // boosted artist should lead the next similar-artist expansion —
        // that's the whole point of the steering signal.
        let sql = """
            SELECT artist,
                   (SUM(CASE WHEN boosted_at IS NOT NULL THEN 1 ELSE 0 END) * 10
                    + SUM(saved) * 3 + SUM(play_count)) AS affinity
            FROM history
            WHERE station_id = ?
            GROUP BY artist_norm
            HAVING affinity > 0
            ORDER BY affinity DESC
            LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        var out: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    out.append(String(cString: c))
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw Error.queryFailed(lastError())
            }
        }
        return out
    }

    // MARK: - v4: selection exclusion log (auditability)

    /// Log every candidate the selection filter dropped this pass. One
    /// transaction and one reused prepared statement, because a single
    /// pool build can produce dozens of exclusions and the log must never
    /// become a reason to stop logging.
    ///
    /// Re-sighting the same (station, artist, title, arm) bumps the
    /// counters and `last_excluded_at` only. `arm`, the duration fields
    /// and `matched_text` are deliberately NOT refreshed: this is a log,
    /// and a log must not rewrite its own past.
    ///
    /// `now` is injectable so tests can assert on ordering deterministically.
    public func recordExclusions(
        _ rows: [ExclusionInput],
        stationID: UUID,
        now: Date = Date()
    ) throws {
        guard !rows.isEmpty else { return }
        guard let db else { throw Error.queryFailed("no db") }

        let sql = """
            INSERT INTO selection_exclusions
              (station_id, artist, title, artist_norm, title_norm,
               duration_seconds, duration_source, arm, matched_text,
               source_kind, source_url, enforced, ever_enforced,
               enforced_count, hit_count, first_excluded_at, last_excluded_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                    ?12, ?12, ?12, 1, ?13, ?13)
            ON CONFLICT(station_id, artist_norm, title_norm, arm) DO UPDATE SET
                hit_count        = selection_exclusions.hit_count + 1,
                last_excluded_at = excluded.last_excluded_at,
                ever_enforced    = MAX(selection_exclusions.ever_enforced,
                                       excluded.enforced),
                enforced_count   = selection_exclusions.enforced_count
                                   + excluded.enforced,
                enforced         = excluded.enforced;
            """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let stationStr = stationID.uuidString
        let stamp = now.timeIntervalSince1970

        try Self.execRaw("BEGIN IMMEDIATE;", on: db)
        do {
            for input in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                sqlite3_bind_text(stmt, 1, stationStr, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, input.artist, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, input.title, -1, SQLITE_TRANSIENT)
                // Same normalization as the history table's dedup key —
                // shared helper on purpose, so "Gas / Pop 1" collapses
                // identically in both places.
                sqlite3_bind_text(stmt, 4, Self.normalize(input.artist), -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, Self.normalize(input.title), -1, SQLITE_TRANSIENT)

                if let seconds = input.durationSeconds {
                    sqlite3_bind_double(stmt, 6, seconds)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                if let source = input.durationSource {
                    sqlite3_bind_text(stmt, 7, source, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }

                sqlite3_bind_text(stmt, 8, input.arm, -1, SQLITE_TRANSIENT)

                if let matched = input.matchedText {
                    sqlite3_bind_text(stmt, 9, matched, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 9)
                }

                sqlite3_bind_text(stmt, 10, input.sourceKind, -1, SQLITE_TRANSIENT)

                if let url = input.sourceURL {
                    sqlite3_bind_text(stmt, 11, url.absoluteString, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 11)
                }

                sqlite3_bind_int64(stmt, 12, input.enforced ? 1 : 0)
                sqlite3_bind_double(stmt, 13, stamp)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw Error.queryFailed(lastError())
                }
            }
        } catch {
            try? Self.execRaw("ROLLBACK;", on: db)
            throw error
        }
        try Self.execRaw("COMMIT;", on: db)
    }

    /// The audit trail, most recently excluded first. `stationID == nil`
    /// reads across every station — "what has the filter been eating?".
    public func exclusions(stationID: UUID? = nil, limit: Int = 100) throws -> [Exclusion] {
        let columns = """
            SELECT id, station_id, artist, title, duration_seconds,
                   duration_source, arm, matched_text, source_kind,
                   source_url, enforced, ever_enforced, enforced_count,
                   hit_count, first_excluded_at, last_excluded_at
            FROM selection_exclusions
            """
        let sql: String
        if stationID == nil {
            sql = columns + "\nORDER BY last_excluded_at DESC LIMIT ?;"
        } else {
            sql = columns + "\nWHERE station_id = ?\nORDER BY last_excluded_at DESC LIMIT ?;"
        }

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        if let stationID {
            sqlite3_bind_text(stmt, 1, stationID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        } else {
            sqlite3_bind_int64(stmt, 1, Int64(limit))
        }

        var out: [Exclusion] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if let row = exclusionRow(from: stmt) { out.append(row) }
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw Error.queryFailed(lastError())
            }
        }
        return out
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

    /// Does `table` already have `column`?
    ///
    /// Cheap insurance that makes every ADD COLUMN replayable. Without it
    /// a re-run of an already-applied migration hits SQLite's "duplicate
    /// column name" and the whole store fails to open.
    private static func columnExists(
        table: String,
        column: String,
        on handle: OpaquePointer
    ) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 1), String(cString: raw) == column {
                return true
            }
        }
        return false
    }

    /// `ALTER TABLE ... ADD COLUMN`, skipped if the column is already there.
    private static func addColumn(
        _ column: String,
        to table: String,
        type: String,
        on handle: OpaquePointer
    ) throws {
        guard !columnExists(table: table, column: column, on: handle) else { return }
        try execRaw("ALTER TABLE \(table) ADD COLUMN \(column) \(type);", on: handle)
    }

    /// Run one migration step and its version bump atomically.
    ///
    /// The steps used to run bare, with `PRAGMA user_version` set only
    /// afterwards. A crash or a deploy's `killall Ratbat` between the two
    /// left a database whose columns existed but whose recorded version
    /// said they did not, and every subsequent open died on "duplicate
    /// column name" — permanently, because the single construction site
    /// swallowed the throw. Reproduced in
    /// `testInterruptedMigrationCanStillBeOpened`.
    ///
    /// SQLite makes DDL and `user_version` transactional, so one
    /// BEGIN/COMMIT round genuinely makes this all-or-nothing.
    private static func migrationStep(
        to version: Int,
        on handle: OpaquePointer,
        _ body: (OpaquePointer) throws -> Void
    ) throws {
        try execRaw("BEGIN IMMEDIATE;", on: handle)
        do {
            try body(handle)
            try execRaw("PRAGMA user_version = \(version);", on: handle)
            try execRaw("COMMIT;", on: handle)
        } catch {
            try? execRaw("ROLLBACK;", on: handle)
            throw error
        }
    }

    /// v5: liveness. One row per station per interval while it is on air.
    ///
    /// history.db records a row only when a track *plays*, so "off air"
    /// and "on air but nobody queued anything" are the same absence of
    /// rows — which is why an overnight outage could not be dated after
    /// the fact. A heartbeat separates the two.
    private static func migrateToV5(on handle: OpaquePointer) throws {
        try execRaw("""
            CREATE TABLE IF NOT EXISTS heartbeat (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                station_id TEXT    NOT NULL,
                at         REAL    NOT NULL,
                listeners  INTEGER NOT NULL DEFAULT 0
            );
            """, on: handle)
        try execRaw(
            "CREATE INDEX IF NOT EXISTS heartbeat_station_at ON heartbeat(station_id, at);",
            on: handle
        )
    }

    // MARK: - Heartbeat

    /// What a station was doing over a window, after the fact.
    public enum Liveness: Equatable, Sendable {
        /// Heartbeats and at least one play.
        case onAirAndPlaying
        /// Heartbeats but no plays — running, nothing queued. NOT an outage.
        case onAirButQuiet
        /// No heartbeats in the window: the station was not running.
        case offAir
    }

    public struct HeartbeatRow: Equatable, Sendable {
        public let at: Date
        public let listeners: Int
    }

    /// A stretch with no heartbeats, i.e. time the station was off air.
    public struct OffAirGap: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    public func recordHeartbeat(station: UUID, at when: Date = Date(), listeners: Int = 0) throws {
        let stmt = try prepare("INSERT INTO heartbeat (station_id, at, listeners) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, when.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(listeners))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.queryFailed(lastError()) }
    }

    public func heartbeats(station: UUID, from: Date, to: Date) throws -> [HeartbeatRow] {
        let stmt = try prepare(
            "SELECT at, listeners FROM heartbeat WHERE station_id = ? AND at >= ? AND at <= ? ORDER BY at ASC;"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, from.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, to.timeIntervalSince1970)
        var rows: [HeartbeatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(HeartbeatRow(
                at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                listeners: Int(sqlite3_column_int(stmt, 1))
            ))
        }
        return rows
    }

    /// The question this table exists to answer.
    public func liveness(station: UUID, from: Date, to: Date) throws -> Liveness {
        guard !(try heartbeats(station: station, from: from, to: to).isEmpty) else {
            return .offAir
        }
        let played = try recentEntries(forStation: station, limit: 1).contains {
            $0.playedAt >= from && $0.playedAt <= to
        }
        return played ? .onAirAndPlaying : .onAirButQuiet
    }

    /// Stretches inside the window with no heartbeat for longer than
    /// `expectedInterval` — i.e. when the station was dark, and for how long.
    public func offAirGaps(
        station: UUID,
        from: Date,
        to: Date,
        expectedInterval: TimeInterval
    ) throws -> [OffAirGap] {
        let beats = try heartbeats(station: station, from: from, to: to)
        guard !beats.isEmpty else { return [OffAirGap(start: from, end: to)] }
        // A gap counts when two consecutive beats are more than twice the
        // expected interval apart — one missed beat is jitter, a run of
        // them is an outage.
        let threshold = expectedInterval * 2
        var gaps: [OffAirGap] = []
        for (previous, next) in zip(beats, beats.dropFirst())
        where next.at.timeIntervalSince(previous.at) > threshold {
            gaps.append(OffAirGap(start: previous.at, end: next.at))
        }
        return gaps
    }

    /// Every station that recorded at least one heartbeat in the window.
    ///
    /// Exists for `/health`: the broadcaster knows what is live right
    /// now, but "was on air earlier today and then went dark" lives only
    /// in this table — and that is precisely the station a health report
    /// must not omit.
    public func stationsWithHeartbeats(from: Date, to: Date) throws -> [UUID] {
        let stmt = try prepare(
            "SELECT DISTINCT station_id FROM heartbeat WHERE at >= ? AND at <= ?;"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
        var stations: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 0),
               let id = UUID(uuidString: String(cString: raw)) {
                stations.append(id)
            }
        }
        return stations
    }

    /// Retention. Returns how many rows were removed.
    @discardableResult
    public func pruneHeartbeats(olderThan cutoff: Date) throws -> Int {
        let stmt = try prepare("DELETE FROM heartbeat WHERE at < ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.queryFailed(lastError()) }
        return Int(sqlite3_changes(db))
    }

    /// The newest schema version. Tests assert against this rather than a
    /// literal, so adding a migration cannot silently rot them.
    public static var latestSchemaVersion: Int { migrations.map(\.0).max() ?? 0 }

    /// The migration ladder, in order. Adding a step means adding a row.
    private static var migrations: [(Int, (OpaquePointer) throws -> Void)] { [
        (1, migrateToV1),
        (2, migrateToV2),
        (3, migrateToV3),
        (4, migrateToV4),
        (5, migrateToV5),
    ] }

    private static func userVersion(on handle: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// v2 adds the taste-intelligence behavioral layer: each row can now
    /// record whether it was explicitly skipped (`skipped` + `skipped_at`)
    /// and how many times the track has been played through (`play_count`).
    /// Fresh DBs created on v2 skip this ALTER and get the columns from
    /// `migrateToV1` once that method is also bumped; for now v1 → v2 is
    /// an additive migration so existing histories keep their data.
    private static func migrateToV2(on handle: OpaquePointer) throws {
        try addColumn("skipped", to: "history", type: "INTEGER NOT NULL DEFAULT 0", on: handle)
        try addColumn("skipped_at", to: "history", type: "REAL", on: handle)
        try addColumn("play_count", to: "history", type: "INTEGER NOT NULL DEFAULT 0", on: handle)
        try execRaw(
            "CREATE INDEX IF NOT EXISTS history_skipped ON history(station_id, skipped, artist_norm);",
            on: handle
        )
    }

    /// Recent plays across every station, newest first — what the public
    /// `/history` endpoint and the Mac history view read. Unlike the
    /// broadcaster's in-memory ring this survives restarts and reaches
    /// back as far as the database goes.
    public func recentEntries(limit: Int = 50, offset: Int = 0) throws -> [Entry] {
        let sql = """
            SELECT id, station_id, artist, title, played_at,
                   source_show_url, youtube_id, saved, cached_path
            FROM history
            ORDER BY played_at DESC
            LIMIT ? OFFSET ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        sqlite3_bind_int64(stmt, 2, Int64(offset))
        return collectRows(stmt)
    }

    /// Recent plays for ONE station, newest first — what the broadcaster
    /// seeds `/now.json`'s `recent` ring from at broadcast start, so "what
    /// just played" survives a restart instead of resetting to `[]`.
    public func recentEntries(forStation station: UUID, limit: Int = 50) throws -> [Entry] {
        let sql = """
            SELECT id, station_id, artist, title, played_at,
                   source_show_url, youtube_id, saved, cached_path
            FROM history
            WHERE station_id = ?
            ORDER BY played_at DESC
            LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        return collectRows(stmt)
    }

    // MARK: - v3: boost / un-♥ API (keep vs steer)

    /// Stamp an entry as boosted — "more of this". The strong steering
    /// signal: outweighs saves in ``topAffinityArtists`` so the boosted
    /// artist leads the next similar-artist expansion, and feeds its own
    /// scoring term above save-affinity.
    public func markBoosted(id: Int64) throws {
        let sql = "UPDATE history SET boosted_at = ? WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Error.queryFailed(lastError())
        }
    }

    /// Boosted entries for a station, newest boost first — the boost
    /// counterpart of ``savedEntries(forStation:limit:)``.
    public func boostedEntries(forStation station: UUID, limit: Int = 100) throws -> [Entry] {
        let sql = """
            SELECT id, station_id, artist, title, played_at,
                   source_show_url, youtube_id, saved, cached_path
            FROM history
            WHERE station_id = ? AND boosted_at IS NOT NULL
            ORDER BY boosted_at DESC
            LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        return collectRows(stmt)
    }

    /// The newest saved row matching a station + artist + title — how
    /// un-♥ finds the row a just-pressed heart created, since playlist
    /// items don't carry the row's id.
    public func newestSavedEntry(station: UUID, artist: String, title: String) throws -> Entry? {
        let sql = """
            SELECT id, station_id, artist, title, played_at,
                   source_show_url, youtube_id, saved, cached_path
            FROM history
            WHERE station_id = ? AND saved = 1
              AND artist_norm = ? AND title_norm = ?
            ORDER BY played_at DESC
            LIMIT 1;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, station.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, Self.normalize(artist), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, Self.normalize(title), -1, SQLITE_TRANSIENT)
        return collectRows(stmt).first
    }

    /// Un-♥ a generative save: the row stays (it's still play history),
    /// only the save flag and the copied file's path are cleared.
    public func unmarkSaved(id: Int64) throws {
        let sql = "UPDATE history SET saved = 0, cached_path = NULL WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Error.queryFailed(lastError())
        }
    }

    /// Un-♥ an affinity-only row (owned/playlist ♥): the row exists ONLY
    /// as the signal, so undo means deleting it outright.
    public func deleteEntry(id: Int64) throws {
        let sql = "DELETE FROM history WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Error.queryFailed(lastError())
        }
    }

    /// v3: the boost signal — "more of this", the strong steering ♥.
    /// NULL = never boosted. Same idempotent-ALTER pattern as v2.
    private static func migrateToV3(on handle: OpaquePointer) throws {
        try addColumn("boosted_at", to: "history", type: "REAL", on: handle)
    }

    /// v4: the selection audit log. The mix-set filter will eventually
    /// drop a 25-minute ambient record the owner would have loved; a
    /// silent filter that can't be audited turns into a quieter, worse
    /// station with no way to diagnose it. Additive like v2/v3 — a new
    /// table, no change to `history`.
    private static func migrateToV4(on handle: OpaquePointer) throws {
        try execRaw("""
            CREATE TABLE IF NOT EXISTS selection_exclusions (
                id                 INTEGER PRIMARY KEY AUTOINCREMENT,
                station_id         TEXT    NOT NULL,
                artist             TEXT    NOT NULL,
                title              TEXT    NOT NULL,
                artist_norm        TEXT    NOT NULL,
                title_norm         TEXT    NOT NULL,
                duration_seconds   REAL,
                duration_source    TEXT,
                arm                TEXT    NOT NULL,
                matched_text       TEXT,
                source_kind        TEXT    NOT NULL,
                source_url         TEXT,
                enforced           INTEGER NOT NULL,
                ever_enforced      INTEGER NOT NULL DEFAULT 0,
                enforced_count     INTEGER NOT NULL DEFAULT 0,
                hit_count          INTEGER NOT NULL DEFAULT 1,
                first_excluded_at  REAL    NOT NULL,
                last_excluded_at   REAL    NOT NULL
            );
            """, on: handle)
        try execRaw("""
            CREATE UNIQUE INDEX IF NOT EXISTS selection_exclusions_key
                ON selection_exclusions(station_id, artist_norm, title_norm, arm);
            """, on: handle)
        try execRaw("""
            CREATE INDEX IF NOT EXISTS selection_exclusions_recent
                ON selection_exclusions(station_id, last_excluded_at DESC);
            """, on: handle)
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

    /// Read one `selection_exclusions` row whose columns match
    /// `(id, station_id, artist, title, duration_seconds, duration_source,
    /// arm, matched_text, source_kind, source_url, enforced, ever_enforced,
    /// enforced_count, hit_count, first_excluded_at, last_excluded_at)`.
    private func exclusionRow(from stmt: OpaquePointer?) -> Exclusion? {
        guard let stmt else { return nil }

        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
                  let cStr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: cStr)
        }

        let id = sqlite3_column_int64(stmt, 0)
        guard let stationStr = text(1), let stationID = UUID(uuidString: stationStr),
              let artist = text(2), let title = text(3),
              let arm = text(6), let sourceKind = text(8) else { return nil }

        var durationSeconds: Double?
        if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
            durationSeconds = sqlite3_column_double(stmt, 4)
        }

        return Exclusion(
            id: id,
            stationID: stationID,
            artist: artist,
            title: title,
            durationSeconds: durationSeconds,
            durationSource: text(5),
            arm: arm,
            matchedText: text(7),
            sourceKind: sourceKind,
            sourceURL: text(9).flatMap { URL(string: $0) },
            enforced: sqlite3_column_int64(stmt, 10) != 0,
            everEnforced: sqlite3_column_int64(stmt, 11) != 0,
            enforcedCount: Int(sqlite3_column_int64(stmt, 12)),
            hitCount: Int(sqlite3_column_int64(stmt, 13)),
            firstExcludedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14)),
            lastExcludedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15))
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

extension HistoryStore.ExclusionInput {
    /// Adapter from the cross-platform ``SelectionExclusionRecord`` the
    /// four sources emit. The two types are structurally identical; they
    /// are separate because this one is macOS-only and ``PlaylistSource``,
    /// which produces these rows, compiles for iOS too.
    public init(_ record: SelectionExclusionRecord) {
        self.init(
            artist: record.artist,
            title: record.title,
            durationSeconds: record.durationSeconds,
            durationSource: record.durationSource,
            arm: record.arm,
            matchedText: record.matchedText,
            sourceKind: record.sourceKind,
            sourceURL: record.sourceURL,
            enforced: record.enforced
        )
    }
}
#endif
