import Foundation

// The steering + transparency half of the web control plane: the two
// listener dials over HTTP (`/policy/get`, `/policy/set`), the taste
// profile the selection pipeline is steering by (`/taste`), and the
// mix-set filter's audit trail (`/exclusions`). A sibling of
// StationWire.swift rather than more of it for the same reason that file
// exists at all: each is a coherent unit that reads, and reviews, on its
// own — stations are catalogue mutations, this file is "what is the
// radio choosing, and why".

extension RadioBroadcaster {

    // MARK: - Requests

    /// JSON body accepted by `POST /policy/set`.
    ///
    /// The double optional on `newMusicShare` is the whole point of the
    /// hand-written decode: the wire must distinguish *absent* ("leave
    /// the dial alone") from *explicit null* ("turn the dial off"),
    /// because the off state is `nil` — NOT `0.0`, which is an active
    /// reorder that leads with owned music (see the sentinel comment on
    /// ``BroadcastPreferences``). A synthesized `Double?` collapses the
    /// two into one and would make "dial off" unreachable over HTTP.
    ///
    /// `.none` = key absent, `.some(nil)` = explicit null,
    /// `.some(.some(x))` = set to x.
    struct PolicySetRequest: Decodable {
        let token: String?
        let newMusicShare: Double??
        let excludeMixSets: Bool?

        enum CodingKeys: String, CodingKey {
            case token, newMusicShare, excludeMixSets
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decodeIfPresent(String.self, forKey: .token)
            newMusicShare = c.contains(.newMusicShare)
                ? .some(try c.decodeIfPresent(Double.self, forKey: .newMusicShare))
                : nil
            excludeMixSets = try c.decodeIfPresent(Bool.self, forKey: .excludeMixSets)
        }
    }

    /// JSON body accepted by `POST /exclusions`. `station` narrows to one
    /// station; absent or explicit null both mean "across every station"
    /// — there is no third meaning, so no double optional here.
    struct ExclusionsRequest: Decodable {
        let token: String?
        let station: String?
        let limit: Int?
    }

    // MARK: - Policy wire shape

    /// The selection policy as both `/policy/get` and `/policy/set`
    /// answer it. Hand-written encode so a nil `newMusicShare` leaves as
    /// an explicit JSON null (the /now.json wire rule: a client must be
    /// able to tell "dial off" from "field not in this build").
    ///
    /// `mixSetMinimumDuration` is READ-ONLY information: the stored
    /// policy hardcodes ``MixSetRule/defaultMinimumDuration`` and the
    /// preferences setter drops whatever arrives, so `/policy/set` never
    /// accepts it — publishing it here is what lets the web render the
    /// threshold honestly without pretending it is a knob.
    struct PolicyPayload: Encodable {
        let newMusicShare: Double?
        let excludeMixSets: Bool
        let mixSetMinimumDuration: Double

        enum CodingKeys: String, CodingKey {
            case newMusicShare, excludeMixSets, mixSetMinimumDuration
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(newMusicShare, forKey: .newMusicShare)
            try c.encode(excludeMixSets, forKey: .excludeMixSets)
            try c.encode(mixSetMinimumDuration, forKey: .mixSetMinimumDuration)
        }
    }

    nonisolated static func encodePolicyPayload(_ policy: SelectionPolicy) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = PolicyPayload(
            newMusicShare: policy.newMusicShare,
            excludeMixSets: policy.excludeMixSets,
            mixSetMinimumDuration: policy.mixSetMinimumDuration
        )
        return (try? encoder.encode(payload))
            ?? Data("{\"status\":\"error\"}".utf8)
    }

    // MARK: - Policy routes

    /// `POST /policy/get` — the two dials plus the read-only mix-set
    /// threshold. Owner-gated: what the owner has chosen to filter is
    /// their business, not a listener's.
    func performPolicyGetAsync(token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }
        return (200, Self.encodePolicyPayload(preferences.selectionPolicy))
    }

    /// `POST /policy/set` — sparse overlay onto the stored policy, then
    /// answer the result in the same shape as get (re-read from the
    /// preferences, so the wire reports what actually persisted).
    ///
    /// Takes effect at each station's next pool refill — the policy is a
    /// live provider re-read per refill, so no restart and no revision
    /// tick. The web UI copy says so.
    func performPolicySetAsync(_ req: PolicySetRequest) async -> (Int, Data) {
        if let rejection = await ownerGate(req.token) { return rejection }
        let current = preferences.selectionPolicy
        // Outer nil = key absent = keep the current value; `.some(nil)` =
        // explicit null = dial off. `??` on the double optional collapses
        // exactly that way. Clamping happens in SelectionPolicy's init —
        // building the value through it rather than mutating fields is
        // what keeps a 1.7 from ever reaching storage.
        let updated = SelectionPolicy(
            newMusicShare: req.newMusicShare ?? current.newMusicShare,
            excludeMixSets: req.excludeMixSets ?? current.excludeMixSets,
            mixSetMinimumDuration: current.mixSetMinimumDuration
        )
        preferences.selectionPolicy = updated
        return (200, Self.encodePolicyPayload(preferences.selectionPolicy))
    }

    // MARK: - /taste

    /// `POST /taste` — what the selection pipeline believes about the
    /// owner's taste, as JSON: the library layer (top artists and tags by
    /// normalized score) plus the behavioral layer per station (the seed
    /// artists driving similar-artist expansion, and how often each
    /// signal has fired). The taste-intelligence design's "taste profile
    /// transparency tab", served to the web instead of a Mac-only view.
    func performTasteAsync(token: String?) async -> (Int, Data) {
        if let rejection = await ownerGate(token) { return rejection }

        struct ScoredArtist: Encodable { let artist: String; let score: Double }
        struct ScoredTag: Encodable { let tag: String; let score: Double }
        struct StationCounts: Encodable {
            let plays: Int; let saves: Int; let boosts: Int; let skips: Int
        }
        struct TasteStation: Encodable {
            let id: String
            let name: String
            let topAffinityArtists: [String]
            let counts: StationCounts
        }
        struct TasteResponse: Encodable {
            let libraryArtists: [ScoredArtist]
            let libraryTags: [ScoredTag]
            let stations: [TasteStation]
        }

        #if os(macOS)
        // The catalogue seam, not the live pipelines: an idle station's
        // accumulated signals are exactly what this surface is for.
        guard let listStations else { return Self.catalogueUnavailable() }
        guard let history else {
            return (500, Self.errorBody("history unavailable"))
        }
        // A broadcaster wired without a profile serves empty library
        // layers rather than refusing — same degrade-not-crash posture as
        // `makeLastFMSource`'s fresh-profile fallback.
        let snapshot = await tasteProfile?.currentSnapshot()
            ?? TasteProfileSnapshot()

        // Top 10 by score; name breaks ties so the wire is deterministic
        // between polls (dictionaries hash-order otherwise).
        let artists = snapshot.libraryArtists
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(10)
            .map { ScoredArtist(artist: $0.key, score: $0.value) }
        let tags = snapshot.libraryTags
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(10)
            .map { ScoredTag(tag: $0.key, score: $0.value) }

        // Same stable ordering as /stations/list, so the two owner
        // surfaces list stations identically.
        let catalogue = listStations().sorted {
            ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString)
        }
        var stations: [TasteStation] = []
        for station in catalogue {
            let seeds = (try? await history.topAffinityArtists(
                forStation: station.id, limit: 5
            )) ?? []
            let counts = (try? await history.signalCounts(forStation: station.id))
                ?? HistoryStore.SignalCounts(plays: 0, saves: 0, boosts: 0, skips: 0)
            stations.append(TasteStation(
                id: station.id.uuidString,
                name: station.name,
                topAffinityArtists: seeds,
                counts: StationCounts(
                    plays: counts.plays, saves: counts.saves,
                    boosts: counts.boosts, skips: counts.skips
                )
            ))
        }
        let response = TasteResponse(
            libraryArtists: artists, libraryTags: tags, stations: stations
        )
        #else
        // No HistoryStore and no TasteProfile off macOS — an empty
        // valid-shape payload, the buildHistoryPayload posture.
        let response = TasteResponse(
            libraryArtists: [], libraryTags: [], stations: []
        )
        #endif

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(response))
            ?? Data("{\"libraryArtists\":[],\"libraryTags\":[],\"stations\":[]}".utf8)
        return (200, body)
    }

    // MARK: - /exclusions

    /// `POST /exclusions` — the mix-set filter's audit trail, a straight
    /// map of ``HistoryStore/exclusions(stationID:limit:)``. Rows with
    /// `enforced: false` are the shadow log: what the filter *would*
    /// remove while the toggle ships off — the exact preview that makes
    /// the default-off state useful rather than merely inert.
    func performExclusionsAsync(_ req: ExclusionsRequest) async -> (Int, Data) {
        if let rejection = await ownerGate(req.token) { return rejection }

        /// One audit row on the wire. Hand-written encode so the fields a
        /// source genuinely can't fill (an NTS row has no duration, a
        /// title-arm row on the duration side has no matched text) leave
        /// as explicit nulls — the /now.json wire rule again.
        struct ExclusionEntry: Encodable {
            let id: Int64
            let stationID: String
            let artist: String
            let title: String
            let arm: String
            let matchedText: String?
            let durationSeconds: Double?
            let durationSource: String?
            let sourceKind: String
            let sourceURL: String?
            let enforced: Bool
            let everEnforced: Bool
            let enforcedCount: Int
            let hitCount: Int
            let firstExcludedAt: Double
            let lastExcludedAt: Double

            enum CodingKeys: String, CodingKey {
                case id, stationID, artist, title, arm, matchedText
                case durationSeconds, durationSource, sourceKind, sourceURL
                case enforced, everEnforced, enforcedCount, hitCount
                case firstExcludedAt, lastExcludedAt
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(stationID, forKey: .stationID)
                try c.encode(artist, forKey: .artist)
                try c.encode(title, forKey: .title)
                try c.encode(arm, forKey: .arm)
                try c.encode(matchedText, forKey: .matchedText)
                try c.encode(durationSeconds, forKey: .durationSeconds)
                try c.encode(durationSource, forKey: .durationSource)
                try c.encode(sourceKind, forKey: .sourceKind)
                try c.encode(sourceURL, forKey: .sourceURL)
                try c.encode(enforced, forKey: .enforced)
                try c.encode(everEnforced, forKey: .everEnforced)
                try c.encode(enforcedCount, forKey: .enforcedCount)
                try c.encode(hitCount, forKey: .hitCount)
                try c.encode(firstExcludedAt, forKey: .firstExcludedAt)
                try c.encode(lastExcludedAt, forKey: .lastExcludedAt)
            }
        }
        struct ExclusionsResponse: Encodable { let exclusions: [ExclusionEntry] }

        // A station key that is present but isn't a UUID is a malformed
        // request, not "all stations" — collapsing it would silently
        // widen a filtered query.
        var stationID: UUID?
        if let raw = req.station {
            guard let parsed = UUID(uuidString: raw) else { return Self.badRequest() }
            stationID = parsed
        }
        let limit = min(max(req.limit ?? 100, 1), 500)

        #if os(macOS)
        guard let history else {
            return (500, Self.errorBody("history unavailable"))
        }
        let rows = (try? await history.exclusions(stationID: stationID, limit: limit)) ?? []
        let entries = rows.map { row in
            ExclusionEntry(
                id: row.id,
                stationID: row.stationID.uuidString,
                artist: row.artist,
                title: row.title,
                arm: row.arm,
                matchedText: row.matchedText,
                durationSeconds: row.durationSeconds,
                durationSource: row.durationSource,
                sourceKind: row.sourceKind,
                sourceURL: row.sourceURL?.absoluteString,
                enforced: row.enforced,
                everEnforced: row.everEnforced,
                enforcedCount: row.enforcedCount,
                hitCount: row.hitCount,
                firstExcludedAt: row.firstExcludedAt.timeIntervalSince1970,
                lastExcludedAt: row.lastExcludedAt.timeIntervalSince1970
            )
        }
        #else
        let entries: [ExclusionEntry] = []
        #endif

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(ExclusionsResponse(exclusions: entries)))
            ?? Data("{\"exclusions\":[]}".utf8)
        return (200, body)
    }
}
