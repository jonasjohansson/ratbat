import Foundation

// The web control plane's wire layer: what a station looks like on the
// way out (``RadioBroadcaster/StationPayload``), what an edit or a create
// looks like on the way in (``StationUpdate``, ``StationDraft``, the
// request mirrors), and the `/stations/*` route handlers themselves.
// A separate file rather than more RadioBroadcaster.swift because that
// file is the entire HTTP layer already — the control plane is a coherent
// unit that reads better, and reviews better, on its own.

// MARK: - StationUpdate

/// Everything the edit surfaces (desktop sheet AND web) can change about
/// a station, in one value handed to ``StationManager/applyUpdate(_:_:)``.
/// `nil` means "leave that knob alone" — an update is a sparse overlay,
/// not a replacement, so a client can rename a station without having to
/// know (or resend) its query.
public struct StationUpdate: Sendable {
    public var name: String?
    public var query: FacetedQuery?
    /// Comfort ↔ Explore dial. Last.fm-only; requesting it on any other
    /// kind is ``StationManager/StationEditError/wrongKind``.
    public var exploration: Double?
    /// Whether the source shuffles its pool. Generative kinds only — a
    /// playlist station reshuffles by design and has no such flag.
    public var shufflePool: Bool?
    #if os(macOS)
    /// Bandcamp's sort dimension; the one knob only Bandcamp has.
    /// Platform-gated exactly like ``BandcampStationConfig``.
    public var sort: BandcampClient.Sort?

    public init(
        name: String? = nil,
        query: FacetedQuery? = nil,
        exploration: Double? = nil,
        shufflePool: Bool? = nil,
        sort: BandcampClient.Sort? = nil
    ) {
        self.name = name
        self.query = query
        self.exploration = exploration
        self.shufflePool = shufflePool
        self.sort = sort
    }
    #else
    public init(
        name: String? = nil,
        query: FacetedQuery? = nil,
        exploration: Double? = nil,
        shufflePool: Bool? = nil
    ) {
        self.name = name
        self.query = query
        self.exploration = exploration
        self.shufflePool = shufflePool
    }
    #endif
}

// MARK: - StationDraft

/// A creatable station, before it exists: the kind plus exactly the knobs
/// that kind supports. The single argument to
/// ``StationManager/createStation(_:name:)`` — an enum rather than a bag
/// of optionals so "an NTS draft with a sort order" is unrepresentable
/// instead of merely rejected.
///
/// Playlist stations are deliberately absent: they are born from a
/// library playlist on the desktop (``StationManager/create(from:)``)
/// and are not creatable over the web.
public enum StationDraft: Sendable {
    case nts(query: FacetedQuery, shufflePool: Bool)
    case lastFM(query: FacetedQuery, shufflePool: Bool, exploration: Double)
    #if os(macOS)
    case bandcamp(query: FacetedQuery, sort: BandcampClient.Sort, shufflePool: Bool)
    #endif

    /// The shared faceted query every draft carries — validation reads it
    /// without switching on kind.
    public var query: FacetedQuery {
        switch self {
        case .nts(let query, _): return query
        case .lastFM(let query, _, _): return query
        #if os(macOS)
        case .bandcamp(let query, _, _): return query
        #endif
        }
    }
}

// MARK: - Wire projection

extension RadioBroadcaster {

    /// Wire spelling of ``Station/Kind``, pinned here so a Swift-side
    /// rename can't silently change the API. `lastFM` (not "lastfm")
    /// because it is the synthesized coding key the on-disk store already
    /// uses — one spelling to maintain, not two.
    nonisolated static func kindLabel(_ kind: Station.Kind) -> String {
        switch kind {
        case .playlist: return "playlist"
        case .nts: return "nts"
        case .lastFM: return "lastFM"
        #if os(macOS)
        case .bandcamp: return "bandcamp"
        #endif
        }
    }

    /// ``FacetedQuery`` as the owner surface sends and receives it. The
    /// key set is the query's own pinned CodingKeys; hand-written so the
    /// year bounds encode as explicit nulls (the `/now.json` wire rule)
    /// and `excludedArtists` leaves as a **sorted** array — it's a `Set`
    /// in Swift, and a hash-ordered wire would diff on every poll.
    struct FacetedQueryPayload: Encodable {
        let query: FacetedQuery

        enum CodingKeys: String, CodingKey {
            case genreTags, yearMin, yearMax, regions
            case tagMatch, popularity
            case excludeOwnedLibrary, excludedArtists
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(query.genreTags, forKey: .genreTags)
            try c.encode(query.yearMin, forKey: .yearMin)
            try c.encode(query.yearMax, forKey: .yearMax)
            try c.encode(query.regions, forKey: .regions)
            try c.encode(query.tagMatch.rawValue, forKey: .tagMatch)
            try c.encode(query.popularity.rawValue, forKey: .popularity)
            try c.encode(query.excludeOwnedLibrary, forKey: .excludeOwnedLibrary)
            try c.encode(query.excludedArtists.sorted(), forKey: .excludedArtists)
        }
    }

    /// One station as `/stations/list` (and the create/update envelopes)
    /// publish it. Same wire-shape rules as `/now.json`: every key present
    /// on every kind, explicit nulls where a kind has nothing to say.
    ///
    /// **The scrub lives in this initializer, not in the callers.** A
    /// playlist station projects to `kind`/`trackCount` and nulls —
    /// never its queue: `Track` carries absolute `file://` URLs, sizes
    /// and dates of the owner's library, and this payload crosses the
    /// tunnel. Enforcing that here means a future route reusing the
    /// payload cannot reintroduce the leak.
    struct StationPayload: Encodable {
        let id: String
        let name: String
        let slug: String
        let kind: String
        let broadcasting: Bool
        let autoStart: Bool
        let query: FacetedQueryPayload?
        let exploration: Double?
        let sort: String?
        let shufflePool: Bool?
        let trackCount: Int?

        init(station: Station, broadcasting: Bool, autoStart: Bool) {
            self.id = station.id.uuidString
            self.name = station.name
            self.slug = station.slug
            self.broadcasting = broadcasting
            self.autoStart = autoStart
            switch station.kind {
            case .playlist(let queue):
                self.kind = "playlist"
                self.query = nil
                self.exploration = nil
                self.sort = nil
                self.shufflePool = nil
                self.trackCount = queue.count
            case .nts(let config):
                self.kind = "nts"
                self.query = FacetedQueryPayload(query: config.query)
                self.exploration = nil
                self.sort = nil
                self.shufflePool = config.shufflePool
                self.trackCount = nil
            case .lastFM(let config):
                self.kind = "lastFM"
                self.query = FacetedQueryPayload(query: config.query)
                self.exploration = config.exploration
                self.sort = nil
                self.shufflePool = config.shufflePool
                self.trackCount = nil
            #if os(macOS)
            case .bandcamp(let config):
                self.kind = "bandcamp"
                self.query = FacetedQueryPayload(query: config.query)
                self.exploration = nil
                self.sort = config.sort.rawValue
                self.shufflePool = config.shufflePool
                self.trackCount = nil
            #endif
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, name, slug, kind, broadcasting, autoStart
            case query, exploration, sort, shufflePool, trackCount
        }

        /// Hand-written for the same reason as ``NowTrack``: `encode`
        /// (not `encodeIfPresent`) turns each nil into an explicit JSON
        /// null instead of a missing key, so two kinds in one payload
        /// never have different key sets.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(slug, forKey: .slug)
            try c.encode(kind, forKey: .kind)
            try c.encode(broadcasting, forKey: .broadcasting)
            try c.encode(autoStart, forKey: .autoStart)
            try c.encode(query, forKey: .query)
            try c.encode(exploration, forKey: .exploration)
            try c.encode(sort, forKey: .sort)
            try c.encode(shufflePool, forKey: .shufflePool)
            try c.encode(trackCount, forKey: .trackCount)
        }
    }

    /// Project a catalogue station onto the wire, reading the live and
    /// auto-start state this broadcaster owns. Auto-start membership is
    /// slug-keyed per-machine preference, so it is read here — the
    /// catalogue seam neither knows nor cares about it.
    func stationPayload(for station: Station) -> StationPayload {
        StationPayload(
            station: station,
            broadcasting: broadcasting.contains(station.id),
            autoStart: preferences.isAutoStart(slug: station.slug)
        )
    }

    // MARK: - Request bodies

    /// `POST /stations/create`. `kind` stays a raw string here — an
    /// unknown kind must surface as a 422 with a message, not as an
    /// opaque decode-failure 400, because "this server doesn't do
    /// libraryRadio yet" is an answer the client is expected to handle.
    struct StationCreateRequest: Decodable {
        let token: String?
        let kind: String
        let name: String?
        let query: FacetedQuery?
        let sort: String?
        let exploration: Double?
        let shufflePool: Bool?
    }

    /// `POST /stations/update`. Absent knobs stay absent — the decode
    /// maps 1:1 onto ``StationUpdate``'s sparse-overlay semantics.
    struct StationUpdateRequest: Decodable {
        let token: String?
        let station: String
        let applyNow: Bool?
        let name: String?
        let query: FacetedQuery?
        let sort: String?
        let exploration: Double?
        let shufflePool: Bool?
    }

    /// `POST /stations/delete|start|stop` — the `LikeRequest` envelope
    /// minus the retro-♥ entry: token plus the station it acts on.
    struct StationActionRequest: Decodable {
        let token: String?
        let station: String
    }

    /// `POST /stations/autostart`.
    struct StationAutoStartRequest: Decodable {
        let token: String?
        let station: String
        let enabled: Bool
    }

    // MARK: - Shared response bodies

    /// JSON-encode an error body properly instead of interpolating the
    /// message into a literal — start failures carry `self.error`, which
    /// is arbitrary text and must not be able to break the JSON.
    nonisolated static func errorBody(_ message: String) -> Data {
        struct ErrorBody: Encodable { let status: String; let message: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(ErrorBody(status: "error", message: message)))
            ?? Data("{\"message\":\"error\",\"status\":\"error\"}".utf8)
    }

    /// 503 for every owner route that needs the catalogue seam before it
    /// is wired — no music folder chosen yet, or a broadcaster running
    /// without a `StationManager` at all. Distinct from 404 so the client
    /// can say "capable but unavailable" instead of hiding the panel.
    nonisolated static func catalogueUnavailable() -> (Int, Data) {
        (503, errorBody("catalogue unavailable"))
    }

    /// 410, not 404, when a station id parses but resolves to nothing:
    /// the route exists, the station is gone. The client maps this to
    /// "station no longer exists" and drops it from its view.
    nonisolated static func stationGone() -> (Int, Data) {
        (410, errorBody("station no longer exists"))
    }

    nonisolated static func unprocessable(_ message: String) -> (Int, Data) {
        (422, errorBody(message))
    }

    /// Map ``StationManager/StationEditError`` onto the wire. Validation
    /// failures are 422; asking a kind for a knob it doesn't have is a
    /// 409 conflict with what the station is; a vanished station is 410.
    nonisolated static func mapEditError(_ error: Error) -> (Int, Data) {
        guard let editError = error as? StationManager.StationEditError else {
            return (500, errorBody("edit failed"))
        }
        switch editError {
        case .unknownStation:
            return stationGone()
        case .emptyGenreTags:
            return unprocessable("station needs at least one tag")
        case .emptyName:
            return unprocessable("station name cannot be empty")
        case .kindHasNoQuery:
            return (409, errorBody("playlist stations have no query"))
        case .wrongKind:
            return (409, errorBody("that setting does not exist on this station kind"))
        }
    }

    nonisolated static func encodeStationEnvelope(_ payload: StationPayload) -> Data {
        struct Envelope: Encodable { let station: StationPayload }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(Envelope(station: payload)))
            ?? Data("{\"station\":null}".utf8)
    }

    // MARK: - Route handlers

    /// `POST /stations/list` — the owner's full catalogue, idle stations
    /// included. Owner-gated (unlike `/now.json`) precisely because idle
    /// stations and their queries are not public knowledge.
    func performStationsListAsync(token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }
        guard let listStations else { return Self.catalogueUnavailable() }
        struct ListResponse: Encodable { let stations: [StationPayload] }
        // Stable name ordering, same as /now.json and /health; id breaks
        // ties so two same-named stations don't jitter between polls.
        let stations = listStations().sorted {
            ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(
            ListResponse(stations: stations.map { stationPayload(for: $0) })
        )) ?? Data("{\"stations\":[]}".utf8)
        return (200, body)
    }

    /// `POST /stations/create` → 201 with the born station (its actual
    /// name — a collision gets the desktop's "(2)" bump, not an error).
    func performStationCreateAsync(_ req: StationCreateRequest) async -> (Int, Data) {
        if let rejection = await ownerGate(req.token) { return rejection }
        guard let createStation else { return Self.catalogueUnavailable() }
        // A create with no query has no tags — same 422 the manager's
        // own validation would produce, answered before kind dispatch so
        // every kind agrees on it.
        guard let query = req.query else {
            return Self.unprocessable("station needs at least one tag")
        }
        let shufflePool = req.shufflePool ?? true
        let draft: StationDraft
        switch req.kind {
        case "nts":
            draft = .nts(query: query, shufflePool: shufflePool)
        case "lastFM":
            // The same gate AddLastFMStationView enforces: a Last.fm
            // station without an API key can never broadcast, so refuse
            // at birth rather than at first start.
            guard !preferences.lastFMAPIKey
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.unprocessable("Last.fm API key not configured")
            }
            draft = .lastFM(
                query: query,
                shufflePool: shufflePool,
                exploration: req.exploration ?? 0.25
            )
        case "bandcamp":
            #if os(macOS)
            guard let sort = BandcampClient.Sort(rawValue: req.sort ?? "date") else {
                return Self.unprocessable("unknown sort")
            }
            draft = .bandcamp(query: query, sort: sort, shufflePool: shufflePool)
            #else
            return Self.unprocessable("unknown kind")
            #endif
        default:
            // Covers "playlist" (desktop-only by design) and kinds this
            // build predates ("libraryRadio") — the web gates its kind
            // picker on /vocab's `kinds`, so this is the backstop.
            return Self.unprocessable("unknown kind")
        }
        do {
            let station = try createStation(draft, req.name)
            pushStationsSSE()
            return (201, Self.encodeStationEnvelope(stationPayload(for: station)))
        } catch {
            return Self.mapEditError(error)
        }
    }

    /// `POST /stations/update`. Persist first, restart second — the
    /// EditStationView crash-ordering rule: a crash between the two
    /// leaves the station saved and merely off its new config until the
    /// next restart, never broadcasting a config that was never saved.
    func performStationUpdateAsync(_ req: StationUpdateRequest) async -> (Int, Data) {
        if let rejection = await ownerGate(req.token) { return rejection }
        guard let updateStation else { return Self.catalogueUnavailable() }
        guard let id = UUID(uuidString: req.station) else { return Self.badRequest() }
        #if os(macOS)
        var update = StationUpdate(
            name: req.name,
            query: req.query,
            exploration: req.exploration,
            shufflePool: req.shufflePool
        )
        if let raw = req.sort {
            guard let sort = BandcampClient.Sort(rawValue: raw) else {
                return Self.unprocessable("unknown sort")
            }
            update.sort = sort
        }
        #else
        if req.sort != nil { return Self.unprocessable("unknown sort") }
        let update = StationUpdate(
            name: req.name,
            query: req.query,
            exploration: req.exploration,
            shufflePool: req.shufflePool
        )
        #endif
        do {
            let updated = try updateStation(id, update)
            // applyUpdate persisted synchronously; only now is the
            // audible interruption allowed. applyNow on an idle station
            // is a no-op — "apply at next start" is already true.
            if req.applyNow == true, isBroadcasting(stationID: updated.id) {
                await restartBroadcast(station: updated)
            }
            pushStationsSSE()
            return (200, Self.encodeStationEnvelope(stationPayload(for: updated)))
        } catch {
            return Self.mapEditError(error)
        }
    }

    /// `POST /stations/delete`. A broadcasting station is stopped first —
    /// deleting a live pipeline in place would strand its encode loop and
    /// its listeners; the stop is the same per-station one the sidebar
    /// uses, so the listener and tunnel stay up for whatever remains.
    /// Name-typing confirmation is the client's job (settled decision).
    func performStationDeleteAsync(_ req: StationActionRequest) async -> (Int, Data) {
        if let rejection = await ownerGate(req.token) { return rejection }
        guard let listStations, let deleteStation else {
            return Self.catalogueUnavailable()
        }
        guard let id = UUID(uuidString: req.station) else { return Self.badRequest() }
        // Resolve before stopping: an unknown id must be a clean 410,
        // not a stop of nothing followed by a shrug.
        guard listStations().contains(where: { $0.id == id }) else {
            return Self.stationGone()
        }
        if isBroadcasting(stationID: id) {
            stopBroadcast(stationID: id)
        }
        guard deleteStation(id) else { return Self.stationGone() }
        pushStationsSSE()
        return (200, Data("{\"status\":\"deleted\"}".utf8))
    }

    /// `POST /stations/start`. Resolved through the catalogue seam, not
    /// `pipelines` — the whole point is starting a station that is idle.
    /// Idempotent: an already-live station answers the same 200 a fresh
    /// start does, so a double-tap can't surface as an error.
    func performStationStartAsync(_ req: StationActionRequest) async -> (Int, Data) {
        if let rejection = await ownerGate(req.token) { return rejection }
        guard let listStations else { return Self.catalogueUnavailable() }
        guard let id = UUID(uuidString: req.station) else { return Self.badRequest() }
        guard let station = listStations().first(where: { $0.id == id }) else {
            return Self.stationGone()
        }
        let started = Data("{\"status\":\"started\"}".utf8)
        if isBroadcasting(stationID: id) { return (200, started) }
        await startBroadcast(station: station)
        guard isBroadcasting(stationID: id) else {
            return (500, Self.errorBody(error ?? "start failed"))
        }
        return (200, started)
    }

    /// `POST /stations/stop`. The public per-station stop: a deliberate
    /// owner gesture, so the "was live" record is forgotten and the next
    /// launch won't resume it. Never `stopAll()` — that tears down the
    /// listener and tunnel the *next* request needs — and never
    /// `tearDownIfEmpty`: the control plane survives zero stations, or
    /// the web could stop the last station and lock itself out.
    /// Idempotent even when the station is idle or unknown.
    func performStationStopAsync(_ req: StationActionRequest) async -> (Int, Data) {
        if let rejection = await ownerGate(req.token) { return rejection }
        guard let id = UUID(uuidString: req.station) else { return Self.badRequest() }
        stopBroadcast(stationID: id)
        return (200, Data("{\"status\":\"stopped\"}".utf8))
    }

    /// `POST /stations/autostart` — flip a station's launch-time
    /// auto-start flag. The membership is slug-keyed per-machine
    /// preference state, written through the injected seam so the
    /// broadcaster stays out of the preferences-ownership business the
    /// same way it stays out of the catalogue's.
    func performStationAutoStartAsync(_ req: StationAutoStartRequest) async -> (Int, Data) {
        if let rejection = await ownerGate(req.token) { return rejection }
        guard let listStations, let setAutoStart else {
            return Self.catalogueUnavailable()
        }
        guard let id = UUID(uuidString: req.station) else { return Self.badRequest() }
        guard let station = listStations().first(where: { $0.id == id }) else {
            return Self.stationGone()
        }
        setAutoStart(req.enabled, station.slug)
        return (200, Data("{\"status\":\"ok\"}".utf8))
    }

    // MARK: - /vocab

    /// JSON for `GET /vocab` — the single source of truth for every
    /// vocabulary the web station forms need, so they never duplicate a
    /// Swift constant. Sourced from ``StationTagPalette`` and the shipped
    /// enums; regions are bare ISO alpha-2 codes (the same
    /// `Locale.Region.isoRegions` source the desktop's region picker
    /// uses) and the client localizes names via `Intl.DisplayNames`.
    ///
    /// `kinds` doubles as the capability signal for what this build can
    /// create over the web — `libraryRadio` joins the list only when the
    /// kind actually ships, which is how the client gates its picker.
    nonisolated static func buildVocabPayload() -> Data {
        struct VocabResponse: Encodable {
            let tags: [String: [String]]
            let tagMatch: [String]
            let popularity: [String]
            let bandcampSort: [String]
            let kinds: [String]
            let regions: [String]
        }
        #if os(macOS)
        // StationTagPalette is macOS-gated with the views; the broadcaster
        // HTTP layer only runs there in practice. The non-macOS branch
        // returns empty palettes, same posture as buildHistoryPayload.
        let tags = [
            "nts": StationTagPalette.nts,
            "lastFM": StationTagPalette.lastFM,
            "bandcamp": StationTagPalette.bandcamp
        ]
        let bandcampSort = [BandcampClient.Sort.date, .pop].map(\.rawValue)
        #else
        let tags: [String: [String]] = ["nts": [], "lastFM": [], "bandcamp": []]
        let bandcampSort = ["date", "pop"]
        #endif
        let response = VocabResponse(
            tags: tags,
            tagMatch: [TagMatch.any, .all].map(\.rawValue),
            popularity: [PopularityTier.hits, .middle, .deepCuts].map(\.rawValue),
            bandcampSort: bandcampSort,
            kinds: ["nts", "lastFM", "bandcamp"],
            // Sorted for a deterministic wire; two-character filter drops
            // the "001"-style numeric world/subregion codes, mirroring
            // FacetedQueryEditor's list.
            regions: Locale.Region.isoRegions
                .map(\.identifier)
                .filter { $0.count == 2 }
                .sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(response)) ?? Data("{}".utf8)
    }
}
