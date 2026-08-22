import Foundation

// The "about this track" surface: `GET /trackinfo` answers with text
// metadata about what a station is playing right now — who made it, when
// it first came out, what else they sound like. A sibling of
// StationWire.swift and SteeringWire.swift for the reason those files
// exist at all: stations are catalogue mutations, steering is "what is
// the radio choosing", this file is "tell me about the thing I'm
// hearing".
//
// Deliberately scoped to the station's CURRENT track (or one still in
// its recent ring): the endpoint takes a station id and an optional
// recent-entry id, never an artist/title pair, so the public internet
// can't use the owner's Last.fm API key as a free lookup proxy — it can
// only ask about music the radio already made public by broadcasting it.

extension RadioBroadcaster {

    // MARK: - Wire shapes

    /// The artist half of `/trackinfo`. Bio, stats, tags and similar
    /// artists come from Last.fm's `artist.getinfo`; `country` from
    /// MusicBrainz, because Last.fm carries no geography. Every field
    /// explicit-null per the /now.json wire rule. There is deliberately
    /// no `onTourOrActive` key: Last.fm retired its events data, so
    /// publishing that flag would be publishing a guess.
    struct TrackInfoArtistPayload: Encodable {
        let bio: String?
        let listeners: Int?
        let playcount: Int?
        let tags: [String]
        let similar: [String]
        let country: String?

        enum CodingKeys: String, CodingKey {
            case bio, listeners, playcount, tags, similar, country
        }

        /// Hand-written so nils leave as explicit JSON nulls rather than
        /// missing keys — a client must be able to tell "Last.fm doesn't
        /// know this artist" from "field not in this build".
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bio, forKey: .bio)
            try c.encode(listeners, forKey: .listeners)
            try c.encode(playcount, forKey: .playcount)
            try c.encode(tags, forKey: .tags)
            try c.encode(similar, forKey: .similar)
            try c.encode(country, forKey: .country)
        }
    }

    /// The track half — Last.fm's `track.getinfo` plus MusicBrainz's
    /// first-release year (Last.fm has no release dates at all).
    struct TrackInfoTrackPayload: Encodable {
        let album: String?
        let playcount: Int?
        let listeners: Int?
        let tags: [String]
        let wiki: String?
        let firstReleaseYear: Int?

        enum CodingKeys: String, CodingKey {
            case album, playcount, listeners, tags, wiki, firstReleaseYear
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(album, forKey: .album)
            try c.encode(playcount, forKey: .playcount)
            try c.encode(listeners, forKey: .listeners)
            try c.encode(tags, forKey: .tags)
            try c.encode(wiki, forKey: .wiki)
            try c.encode(firstReleaseYear, forKey: .firstReleaseYear)
        }
    }

    /// The whole `/trackinfo` answer. The top-level identity fields echo
    /// what /now.json already said about this track, so a client can
    /// render the card from this one response without correlating
    /// payloads. `artistInfo`/`trackInfo` are null only when the track
    /// carries no artist (or no title) to ask about — enrichment that
    /// merely FAILED still answers an object full of nulls, because "we
    /// asked and nobody knew" and "there was nothing to ask about" are
    /// different facts.
    struct TrackInfoResponse: Encodable {
        let artist: String
        let title: String
        let album: String?
        let origin: String
        let sourceURL: String?
        let youtubeURL: String?
        let artistInfo: TrackInfoArtistPayload?
        let trackInfo: TrackInfoTrackPayload?

        enum CodingKeys: String, CodingKey {
            case artist, title, album, origin, sourceURL, youtubeURL
            case artistInfo, trackInfo
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(artist, forKey: .artist)
            try c.encode(title, forKey: .title)
            try c.encode(album, forKey: .album)
            try c.encode(origin, forKey: .origin)
            try c.encode(sourceURL, forKey: .sourceURL)
            try c.encode(youtubeURL, forKey: .youtubeURL)
            try c.encode(artistInfo, forKey: .artistInfo)
            try c.encode(trackInfo, forKey: .trackInfo)
        }
    }

    // MARK: - Query parsing

    /// Pull `station` / `entry` out of a `/trackinfo?…` path. The router
    /// keeps the query string on the path (the /history idiom), so this
    /// is the same tiny hand parse — the values are bare UUIDs, nothing
    /// here needs percent-decoding.
    nonisolated static func trackInfoQuery(path: String) -> (station: String?, entry: String?) {
        var station: String?
        var entry: String?
        if let q = path.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0] == "station" { station = String(kv[1]) }
                if kv[0] == "entry" { entry = String(kv[1]) }
            }
        }
        return (station, entry)
    }

    // MARK: - /trackinfo

    #if os(macOS)
    /// The one place `/trackinfo` gets its Last.fm client. Reuses the
    /// slot on ``trackInfoLastFM`` while the preferences key is
    /// unchanged (cache continuity across polls), rebuilds it the moment
    /// the key changes (key edits bite without a restart, matching
    /// `lastFMClientIfAvailable()`), and clears it when the key is
    /// removed — keyless means enrichment off, not stale.
    func lastFMForTrackInfo() -> LastFMClient? {
        let key = preferences.lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            trackInfoLastFM = nil
            return nil
        }
        if let slot = trackInfoLastFM, slot.apiKey == key { return slot.client }
        let client = LastFMClient(apiKey: key)
        trackInfoLastFM = (apiKey: key, client: client)
        return client
    }
    #endif

    /// `GET /trackinfo?station=<uuid>[&entry=<recent entryID>]` — public,
    /// like /now.json: it describes only what the station is currently
    /// broadcasting, or a track still in the recent ring /now.json also
    /// publishes, so nothing leaves here that wasn't public already.
    ///
    /// Enrichment degrades, never errors: a missing API key, an upstream
    /// outage, or an artist nobody has catalogued all answer 200 with
    /// nulls in the gaps (`tags`/`similar` degrade to `[]`). The only
    /// 404s are "there is no track to describe" — unknown or idle
    /// station, or an entry that has left the ring; ids that don't parse
    /// are the shared 400, same as every body route.
    func performTrackInfoAsync(path: String) async -> (Int, Data) {
        let query = Self.trackInfoQuery(path: path)
        guard let rawStation = query.station,
              let stationID = UUID(uuidString: rawStation) else {
            return Self.badRequest()
        }

        let item: TrackSourceItem
        if let rawEntry = query.entry {
            guard let entryID = UUID(uuidString: rawEntry) else {
                return Self.badRequest()
            }
            // The same ring /like's retro-♥ reads: an entry that has
            // scrolled out is gone, not an error worth 500ing over.
            guard let recent = recentByStation[stationID]?
                .first(where: { $0.entryID == entryID }) else {
                return (404, Self.errorBody("not in recent history"))
            }
            item = recent.item
        } else {
            // Unknown station and idle station land here identically —
            // the broadcaster only knows live stations, so it cannot
            // (and should not) tell a stranger which is which.
            guard let current = currentItemByStation[stationID] else {
                return (404, Self.errorBody("no current track"))
            }
            item = current
        }

        let artist = (item.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var artistPayload: TrackInfoArtistPayload?
        var trackPayload: TrackInfoTrackPayload?
        #if os(macOS)
        if !artist.isEmpty {
            let lastFM = lastFMForTrackInfo()
            let mb = trackInfoMusicBrainzOverride ?? musicBrainz
            // Last.fm for the words and the crowd numbers, MusicBrainz
            // only for the facts Last.fm doesn't have (country, first
            // release year) — no double-asking, and MB's 1 req/s throttle
            // is left to its own actor. `try?` throughout: enrichment
            // failing is not the radio failing, so upstream trouble
            // leaves nulls, never a 5xx.
            var lfArtist: LastFMClient.ArtistInfo?
            if let lastFM { lfArtist = try? await lastFM.artistInfo(artist) }
            let country = await mb.countryCode(forArtist: artist)
            artistPayload = TrackInfoArtistPayload(
                bio: lfArtist?.bio,
                listeners: lfArtist?.listeners,
                playcount: lfArtist?.playcount,
                tags: lfArtist?.tags ?? [],
                // Five names is a card's worth; the client can always ask
                // Last.fm for the long tail itself.
                similar: Array((lfArtist?.similar ?? []).prefix(5)),
                country: country
            )
            if !title.isEmpty {
                var lfTrack: LastFMClient.TrackInfo?
                if let lastFM { lfTrack = try? await lastFM.trackInfo(artist: artist, title: title) }
                let year = await mb.firstReleaseYear(artist: artist, title: title)
                trackPayload = TrackInfoTrackPayload(
                    album: lfTrack?.album,
                    playcount: lfTrack?.playcount,
                    listeners: lfTrack?.listeners,
                    tags: lfTrack?.tags ?? [],
                    wiki: lfTrack?.wiki,
                    firstReleaseYear: year
                )
            }
        }
        #endif
        // Off macOS there are no Last.fm / MusicBrainz clients to ask —
        // the envelope still answers in full, nulls where the facts
        // would go, the buildHistoryPayload posture.

        let response = TrackInfoResponse(
            artist: artist,
            title: title,
            album: item.album,
            origin: item.origin.rawValue,
            sourceURL: item.sourceURL,
            youtubeURL: item.youtubeURL,
            artistInfo: artistPayload,
            trackInfo: trackPayload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(response))
            ?? Data("{\"status\":\"error\",\"message\":\"encoding failed\"}".utf8)
        return (200, body)
    }
}
