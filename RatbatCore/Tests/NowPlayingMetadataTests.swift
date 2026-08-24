#if os(macOS)
import XCTest
import AVFoundation
@testable import RatbatCore

/// `/now.json` used to describe a track differently depending on where it
/// came from: Bandcamp items carried `sourceURL` + `youtubeURL`, library
/// items carried neither, and `album` was hard-coded to `""` for
/// everything. A client could not tell "this source has no album" from
/// "this build forgot to plumb album through".
///
/// These tests pin the wire contract instead: every track object — current,
/// recent, or next — carries the SAME key set, `null` where the source
/// genuinely cannot supply a value, and an `origin` naming the source so a
/// null is attributable rather than mysterious.
final class NowPlayingMetadataTests: XCTestCase {

    /// The key set every track object in `/now.json` must carry, whatever
    /// its source. `recent` entries add `entryID` + `playedAt` on top.
    /// Every track object carries every key, in every position — the
    /// invariant this file exists to defend. `elapsedSeconds` is null
    /// anywhere but the current track (a finished one has no position and
    /// an upcoming one has not started), but the KEY is there, so a client
    /// can tell "not playing" from "this build doesn't say".
    static let trackKeys: Set<String> = [
        "album", "artist", "artworkURL", "durationSeconds", "elapsedSeconds",
        "origin", "sourceURL", "title", "youtubeURL",
    ]

    // MARK: - Library metadata reaches the wire

    /// Library tracks carry album + duration in their `Track` value — the
    /// indexer parses both. They were dropped at the `TrackSourceItem`
    /// boundary, so `/now.json` reported `"album": ""` for every library
    /// station. Both must survive to the wire.
    @MainActor
    func testLibraryTrackPublishesAlbumAndDuration() async throws {
        let tracks = try await Self.taggedFixtureTracks()
        let port: UInt16 = 18_060
        let radio = RadioBroadcaster(port: port, publishesPublicly: false)
        let station = Station(name: "Album Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let current = try await Self.currentTrackObject(port: port)
        XCTAssertEqual(current["album"] as? String, "Fixture Album")
        XCTAssertEqual(current["origin"] as? String, "library")
        let duration = try XCTUnwrap(current["durationSeconds"] as? Double)
        XCTAssertGreaterThan(duration, 0, "library duration should reach the wire")
    }

    /// Shape uniformity: the current track, every recent entry and the
    /// prefetched next track all expose the same keys. A key present on one
    /// and absent on another is the defect this pins shut.
    @MainActor
    func testTrackObjectsShareOneKeySetAcrossPositions() async throws {
        let tracks = try await Self.taggedFixtureTracks()
        guard tracks.count >= 2 else { throw XCTSkip("Need 2+ fixtures") }
        let port: UInt16 = 18_061
        let radio = RadioBroadcaster(port: port, publishesPublicly: false)
        let station = Station(name: "Shape Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        // A parked encode loop never advances — the data-conscious idle
        // holds after track one — so nothing would ever retire into the
        // recent ring. Attach a listener and KEEP it attached: the idle
        // gate re-arms the moment the last listener drops, so a listener
        // that stops early leaves `nextTrack` unpublished.
        let listener = Task {
            _ = try? await Self.drainStream(
                port: port, path: "/stream/\(station.slug).aac"
            )
        }
        defer { listener.cancel() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        radio.nextTrack(stationID: station.id)

        // Poll rather than sleep a fixed budget: the skip lands on the next
        // loop iteration and the idle gate polls every 5s, so the wait is
        // real but not fixed.
        var station0: [String: Any] = [:]
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            station0 = try await Self.stationObject(port: port)
            let hasRecent = !((station0["recent"] as? [[String: Any]]) ?? []).isEmpty
            if hasRecent && station0["nextTrack"] is [String: Any] { break }
        }
        let current = try XCTUnwrap(station0["currentTrack"] as? [String: Any])
        XCTAssertEqual(Set(current.keys), Self.trackKeys)

        let next = try XCTUnwrap(station0["nextTrack"] as? [String: Any])
        XCTAssertEqual(Set(next.keys), Self.trackKeys)

        let recent = try XCTUnwrap(station0["recent"] as? [[String: Any]])
        XCTAssertFalse(recent.isEmpty, "advancing a track must retire it into recent")
        for entry in recent {
            XCTAssertEqual(
                Set(entry.keys),
                Self.trackKeys.union(["entryID", "playedAt"]),
                "recent entries are track objects plus their own identity"
            )
        }
    }

    /// `recent: []` was returned on every station on every poll: the ring is
    /// in-memory only, so a restart emptied it, and with no listener the
    /// encode loop parks after track one and never retires anything. Seeding
    /// from the durable history at broadcast start makes the field mean
    /// something the moment a station goes live.
    @MainActor
    func testRecentIsSeededFromHistoryAtBroadcastStart() async throws {
        let tracks = try await Self.taggedFixtureTracks()
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-seed-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.port = 18_062
        defer { prefs.port = 18_000 }

        let station = Station(name: "Seed Test", kind: .playlist(queue: tracks))
        // Two plays already on the books from a previous run of this station.
        _ = try await store.record(
            station: station.id, artist: "Prior Artist", title: "Prior Title",
            playedAt: Date().addingTimeInterval(-600),
            cachedPath: tracks[0].url.path
        )
        _ = try await store.record(
            station: station.id, artist: "Older Artist", title: "Older Title",
            playedAt: Date().addingTimeInterval(-1200),
            cachedPath: tracks[0].url.path
        )

        let radio = RadioBroadcaster(
            preferences: prefs, history: store, publishesPublicly: false
        )
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let stationObj = try await Self.stationObject(port: 18_062)
        let recent = try XCTUnwrap(stationObj["recent"] as? [[String: Any]])
        let titles = recent.compactMap { $0["title"] as? String }
        XCTAssertTrue(
            titles.contains("Prior Title"),
            "history-backed recent should survive a restart; got \(titles)"
        )
        XCTAssertTrue(
            titles.firstIndex(of: "Prior Title") ?? 99
                < titles.firstIndex(of: "Older Title") ?? 0,
            "newest first; got \(titles)"
        )
    }

    // MARK: - Artwork

    /// A library file with embedded cover art gets an `artworkURL` pointing
    /// at this server, and that URL serves real image bytes. Files without
    /// art report `null` rather than a URL that 404s.
    @MainActor
    func testEmbeddedArtworkIsAdvertisedAndServed() async throws {
        let tracks = try await Self.taggedFixtureTracks()
        let port: UInt16 = 18_063
        let radio = RadioBroadcaster(port: port, publishesPublicly: false)
        let station = Station(name: "Artwork Test", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }

        try await Task.sleep(nanoseconds: 2_000_000_000)

        let current = try await Self.currentTrackObject(port: port)
        let artworkURL = try XCTUnwrap(
            current["artworkURL"] as? String,
            "the tagged fixture carries embedded art"
        )
        XCTAssertTrue(artworkURL.hasPrefix("/artwork/"), artworkURL)

        let url = URL(string: "http://127.0.0.1:\(port)\(artworkURL)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(
            (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
            "image/jpeg"
        )
        XCTAssertGreaterThan(data.count, 100, "expected real image bytes")
    }

    /// An unknown artwork id must 404 rather than 200-with-nothing — a
    /// client that caches a zero-byte "image" shows a broken tile forever.
    @MainActor
    func testUnknownArtworkIDReturns404() async throws {
        let tracks = try await Self.taggedFixtureTracks()
        let port: UInt16 = 18_064
        let radio = RadioBroadcaster(port: port, publishesPublicly: false)
        let station = Station(name: "Artwork 404", kind: .playlist(queue: tracks))
        await radio.startBroadcast(station: station)
        defer { radio.stopAll() }
        try await Task.sleep(nanoseconds: 800_000_000)

        let url = URL(string: "http://127.0.0.1:\(port)/artwork/deadbeefdeadbeef.jpg")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    // MARK: - Synthetic resolver ids are not YouTube links

    /// Bandcamp resolves by direct URL, so the resolver hands back a
    /// SYNTHETIC id like `bandcampalbum:agonic-tenebrae`. That was being
    /// pasted into a `watch?v=` template, and `/now.json` shipped
    /// `https://www.youtube.com/watch?v=bandcampalbum:agonic-tenebrae` —
    /// a link that 404s — as if it were provenance. Only a real catalog id
    /// becomes a URL.
    func testOnlyRealYouTubeIDsBecomeWatchURLs() {
        XCTAssertEqual(
            TrackSourceItem.youtubeWatchURL(for: "dQw4w9WgXcQ"),
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
        XCTAssertNil(TrackSourceItem.youtubeWatchURL(for: "bandcampalbum:agonic-tenebrae"))
        XCTAssertNil(TrackSourceItem.youtubeWatchURL(for: "bandcamp:123"))
        XCTAssertNil(TrackSourceItem.youtubeWatchURL(for: nil))
        XCTAssertNil(TrackSourceItem.youtubeWatchURL(for: "short"))
        XCTAssertNil(TrackSourceItem.youtubeWatchURL(for: "twelvechars!"))
    }

    /// The artwork route is a dictionary lookup, not a file server. Only
    /// lowercase hex ids of our own making are even parsed.
    func testArtworkPathParsingRejectsAnythingButOurIDs() {
        XCTAssertEqual(
            RadioBroadcaster.extractArtworkID(from: "/artwork/a1b2c3d4.jpg"), "a1b2c3d4"
        )
        XCTAssertNil(RadioBroadcaster.extractArtworkID(from: "/artwork/.jpg"))
        XCTAssertNil(RadioBroadcaster.extractArtworkID(from: "/artwork/../etc/passwd.jpg"))
        XCTAssertNil(RadioBroadcaster.extractArtworkID(from: "/artwork/A1B2.jpg"))
        XCTAssertNil(RadioBroadcaster.extractArtworkID(from: "/artwork/zzzz.jpg"))
        XCTAssertNil(RadioBroadcaster.extractArtworkID(from: "/artwork/a1b2c3d4.png"))
    }

    // MARK: - Probe unit

    /// The probe reads what is actually in the file and invents nothing:
    /// art out of a tagged file, `nil` out of an untagged one.
    func testTrackFileProbeReadsEmbeddedArtworkAndNilsWhenAbsent() async throws {
        let tagged = try await Self.taggedFixtureTracks()
        let art = await TrackFileProbe.artworkJPEG(of: tagged[0].url)
        XCTAssertNotNil(art, "tagged fixture should yield artwork bytes")
        XCTAssertGreaterThan(art?.count ?? 0, 100)

        let bare = try await Self.bareFixtureTracks()
        let none = await TrackFileProbe.artworkJPEG(of: bare[0].url)
        XCTAssertNil(none, "untagged fixture must not invent artwork")
    }

    // MARK: - Helpers

    /// Untouched bundle fixtures — no album tag, no cover art.
    nonisolated static func bareFixtureTracks() async throws -> [Track] {
        let bundle = Bundle(for: NowPlayingMetadataTests.self)
        guard let root = bundle.url(
            forResource: "library", withExtension: nil, subdirectory: "Fixtures"
        ) ?? bundle.resourceURL?.appendingPathComponent("Fixtures/library") else {
            throw XCTSkip("Fixtures missing")
        }
        let playlists = try await LibraryIndexer().scan(folder: root)
        guard let tracks = playlists.first?.tracks, !tracks.isEmpty else {
            throw XCTSkip("Fixtures empty")
        }
        return tracks
    }

    /// Bundle fixtures re-exported with an album tag and embedded cover
    /// art, so the metadata path has something real to carry. Cached per
    /// process — the export is the slow part of these tests.
    nonisolated static func taggedFixtureTracks() async throws -> [Track] {
        if let cached = TaggedFixtures.shared.tracks { return cached }
        let bare = try await bareFixtureTracks()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratbat-tagged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var out: [Track] = []
        for (index, track) in bare.prefix(3).enumerated() {
            let dest = dir.appendingPathComponent("tagged-\(index).m4a")
            try await exportTagged(source: track.url, to: dest)
            out.append(Track(
                url: dest,
                title: "Tagged \(index)",
                artist: "Fixture Artist",
                album: "Fixture Album",
                duration: track.duration > 0 ? track.duration : 12
            ))
        }
        guard !out.isEmpty else { throw XCTSkip("Could not build tagged fixtures") }
        TaggedFixtures.shared.tracks = out
        return out
    }

    /// Passthrough-remux the fixture into a new m4a carrying an album tag
    /// and a JPEG cover. Skips the whole suite if the export refuses —
    /// better an honest skip than a test that silently proves nothing.
    nonisolated private static func exportTagged(source: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else {
            throw XCTSkip("No passthrough export session available")
        }

        let album = AVMutableMetadataItem()
        album.identifier = .commonIdentifierAlbumName
        album.value = "Fixture Album" as NSString

        let artwork = AVMutableMetadataItem()
        artwork.identifier = .commonIdentifierArtwork
        artwork.dataType = kCMMetadataBaseDataType_JPEG as String
        artwork.value = jpegSwatch() as NSData

        export.outputURL = dest
        export.outputFileType = .m4a
        export.metadata = [album, artwork]
        // `export()` (async, no arguments) is macOS 15+; the deployment
        // target here is 14.0, so bridge the completion-handler flavour.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw XCTSkip("Tagged fixture export produced no file")
        }
    }

    /// Smallest honest JPEG we can make without shipping a binary fixture:
    /// a solid-colour bitmap encoded through ImageIO.
    nonisolated private static func jpegSwatch() -> Data {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0x33; pixels[i + 1] = 0x66
            pixels[i + 2] = 0x99; pixels[i + 3] = 0xFF
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            out, "public.jpeg" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    nonisolated static func stationObject(port: UInt16) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)/now.json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let stations = json?["stations"] as? [[String: Any]] ?? []
        guard let first = stations.first else {
            throw XCTSkip("no live station in /now.json")
        }
        return first
    }

    nonisolated static func currentTrackObject(port: UInt16) async throws -> [String: Any] {
        let station = try await stationObject(port: port)
        guard let current = station["currentTrack"] as? [String: Any] else {
            throw XCTSkip("encoder had not opened a track yet")
        }
        return current
    }

    /// Pull bytes off a station's AAC stream so the encode loop sees an
    /// audience and stops idling. Runs until the calling task is cancelled —
    /// the gate re-arms as soon as the last listener drops, so the audience
    /// has to outlive whatever the test is waiting for.
    nonisolated static func drainStream(port: UInt16, path: String) async throws -> Int {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let (bytes, _) = try await URLSession.shared.bytes(from: url)
        var count = 0
        for try await _ in bytes {
            count += 1
            if Task.isCancelled { break }
        }
        return count
    }
}

/// Process-wide cache for the exported fixtures. A plain final class behind
/// a `nonisolated(unsafe)` static: the tests that touch it run serially
/// within one XCTest process, and rebuilding the export per test costs more
/// than the whole rest of the suite.
private final class TaggedFixtures: @unchecked Sendable {
    static let shared = TaggedFixtures()
    var tracks: [Track]?
}
#endif
