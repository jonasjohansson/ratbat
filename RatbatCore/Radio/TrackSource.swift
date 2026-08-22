import Foundation

/// Abstract supplier of "play this audio file next" URLs for the
/// broadcaster. Two concrete impls ship with Ratbat:
///
///   * ``PlaylistSource`` — a static queue, looped forever
///   * ``NTSSource`` — a live generative feed curated from NTS Radio
///
/// Sources are async because NTS-style feeds need to scrape + download
/// before they can hand back a URL. Returning `nil` means "no more
/// tracks available right now" — the broadcaster will stop the pipeline
/// (it's fine to restart from the top later).
public protocol TrackSource: Actor {
    /// Next audio file URL to play, or nil if the source is exhausted.
    /// May take a noticeable amount of time (download-on-demand).
    func nextURL() async throws -> TrackSourceItem?

    /// The owner steered (boosted a track): sources that can re-aim their
    /// candidate pool should schedule a refill; the rest ignore it.
    ///
    /// A nudge, never a skip — steering affects the pool, not the needle,
    /// so a station mid-track always finishes the track. Default is a
    /// no-op because only Last.fm has a similar-artist graph to re-seed
    /// from: NTS pools are show-based and Bandcamp's discover API has no
    /// similar-artist endpoint, so on those kinds (and playlists) boost
    /// remains a rating signal that steers at the next natural refill.
    func noteSteeringChanged() async
}

public extension TrackSource {
    func noteSteeringChanged() async {}
}

/// Where a ``TrackSourceItem`` came from.
///
/// Published verbatim as `/now.json`'s `origin` so a client can attribute a
/// null field to its source instead of guessing whether the field is
/// unsupported or merely un-plumbed. Which fields each origin can fill is
/// documented on ``TrackSourceItem``.
public enum TrackOrigin: String, Sendable, Codable, Hashable {
    /// A file the user already owns, indexed by ``LibraryIndexer``.
    case library
    case nts
    case lastFM = "lastfm"
    case bandcamp
}

/// Metadata-bearing handle to the next track a ``TrackSource`` hands
/// the broadcaster. URL points at a local, decodable file; the string
/// fields feed ICY, the "Now:" UI snippet, and `/now.json`.
///
/// ## What each origin can supply
///
/// | field         | library            | nts / lastfm / bandcamp |
/// |---------------|--------------------|-------------------------|
/// | `album`       | file tag           | resolver metadata       |
/// | `duration`    | file tag           | resolver metadata       |
/// | `artworkURL`  | embedded art, served by us | remote CDN thumbnail |
/// | `sourceURL`   | — (the file IS the source) | release / show page |
/// | `youtubeURL`  | — (never resolved) | resolver match          |
///
/// A dash means the origin genuinely has no such value, and the field is
/// `nil` for that reason rather than because nobody wired it up.
public struct TrackSourceItem: Sendable {
    public let url: URL
    /// Human-readable metadata for ICY and logs. `nil` fields are fine.
    public let artist: String?
    public let title: String?
    /// Album / release title. `nil` when the file carries no album tag or
    /// the resolver's metadata didn't include one — singles legitimately
    /// have no album.
    public let album: String?
    /// Playing time in seconds, `nil` when unknown.
    public let duration: TimeInterval?
    /// Cover art. Absolute for remote CDN thumbnails; the broadcaster
    /// rewrites embedded local art into a `/artwork/{id}.jpg` path it
    /// serves itself (see ``TrackFileProbe``).
    public let artworkURL: String?
    /// Where this track came from on the web — a Bandcamp release page, an
    /// NTS show. `nil` for library files: the file is the source.
    public let sourceURL: String?
    /// The YouTube / YouTube Music watch URL the resolver matched, when the
    /// audio came from there.
    public let youtubeURL: String?
    /// Which kind of source produced this item.
    public let origin: TrackOrigin
    /// History row id, when the play was recorded. Since the history
    /// slice this is populated for playlist sources too, so it no longer
    /// doubles as "is this a transient download?" — see ``isOwned``.
    public let historyID: Int64?
    /// True when `url` points at a file already in the user's library
    /// (playlist sources), false for transient cache downloads awaiting
    /// a ♥. Decides whether ♥ copies a file or just records affinity;
    /// previously inferred from `historyID == nil`, which stopped being
    /// true once playlist plays started being recorded.
    public let isOwned: Bool

    public init(
        url: URL,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        artworkURL: String? = nil,
        sourceURL: String? = nil,
        youtubeURL: String? = nil,
        origin: TrackOrigin = .library,
        historyID: Int64? = nil,
        isOwned: Bool = false
    ) {
        self.url = url
        self.artist = artist
        self.title = title
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.sourceURL = sourceURL
        self.youtubeURL = youtubeURL
        self.origin = origin
        self.historyID = historyID
        self.isOwned = isOwned
    }

    /// Build an item for a generative source (NTS / Last.fm / Bandcamp),
    /// which all resolve through ``TrackResolver`` and therefore share one
    /// shape.
    ///
    /// `youtubeID` is filtered rather than trusted: the direct-URL resolver
    /// path returns a SYNTHETIC id of the form `"<extractor>:<id>"` (e.g.
    /// `"bandcampalbum:agonic-tenebrae"`), and pasting that into a
    /// `watch?v=` template produced a link that 404s on YouTube. Only a
    /// real 11-character catalog id becomes a watch URL; anything else
    /// reports `nil`, which is the truth.
    public static func generative(
        url: URL,
        artist: String?,
        title: String?,
        album: String?,
        duration: TimeInterval?,
        artworkURL: String?,
        sourceURL: URL?,
        youtubeID: String?,
        origin: TrackOrigin,
        historyID: Int64?
    ) -> TrackSourceItem {
        TrackSourceItem(
            url: url,
            artist: artist,
            title: title,
            album: album,
            duration: duration,
            artworkURL: artworkURL,
            sourceURL: sourceURL?.absoluteString,
            youtubeURL: youtubeWatchURL(for: youtubeID),
            origin: origin,
            historyID: historyID,
            isOwned: false
        )
    }

    /// A real YouTube video id is 11 characters of `[A-Za-z0-9_-]`. The
    /// resolver's synthetic ids always carry a `:`, so they never pass.
    static func youtubeWatchURL(for id: String?) -> String? {
        guard let id, id.count == 11 else { return nil }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "https://www.youtube.com/watch?v=\(id)"
    }

    /// Copy carrying what the broadcaster could only learn by opening the
    /// file — embedded cover art, and the file's true playing time.
    ///
    /// Both are resolved after the source has already handed the item over,
    /// because both need the decoder to have the file open.
    ///
    /// A measured duration WINS over a reported one. The file is what the
    /// listener hears; the metadata is a claim about it. They diverge for
    /// real: a Bandcamp album download reports per-track durations for a
    /// playlist while the file on disk is one unidentified member of it.
    /// `nil` leaves whatever the source reported alone.
    public func withProbedFile(
        artworkURL probedArtwork: String?,
        duration measured: TimeInterval?
    ) -> TrackSourceItem {
        TrackSourceItem(
            url: url, artist: artist, title: title, album: album,
            duration: measured ?? duration,
            artworkURL: probedArtwork ?? artworkURL,
            sourceURL: sourceURL,
            youtubeURL: youtubeURL, origin: origin, historyID: historyID,
            isOwned: isOwned
        )
    }
}
