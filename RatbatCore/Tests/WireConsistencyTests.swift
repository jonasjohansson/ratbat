#if os(macOS)
import XCTest
@testable import RatbatCore

/// Two rules were applied to `/now.json`'s track objects and then not
/// carried through the rest of the wire. Verifying the deploy from outside
/// is what surfaced both:
///
/// 1. **A synthetic resolver id is not a YouTube link.** `/now.json` stopped
///    minting `watch?v=bandcampalbum:…` URLs that 404. `/history` went on
///    doing it — it builds the URL from the raw `youtube_id` column.
/// 2. **A field is present or explicitly null, never quietly missing.** The
///    track objects obey that. The station object around them did not:
///    `currentTrack` and `nextTrack` were dropped entirely when absent, so
///    a station with nothing prefetched had no `nextTrack` key while its
///    neighbour did — the same "present for one, missing for another"
///    complaint, one level up.
final class WireConsistencyTests: XCTestCase {

    /// `/history` must apply the same filter `/now.json` does. Observed on
    /// the live radio after deploying: `/now.json` reported
    /// `"youtubeURL": null` for a Bandcamp track while `/history` reported
    /// `"https://www.youtube.com/watch?v=bandcampalbum:crooked-rain-…"`
    /// for the very same play.
    @MainActor
    func testHistoryDoesNotMintYouTubeLinksFromSyntheticIDs() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("wire-\(UUID().uuidString).sqlite")
        let store = try await HistoryStore(databaseURL: tempDB)
        let prefs = BroadcastPreferences()
        prefs.port = 18_090
        defer { prefs.port = 18_000 }
        let station = UUID()

        _ = try await store.record(
            station: station, artist: "Pavement", title: "Synthetic",
            youtubeID: "bandcampalbum:crooked-rain-crooked-rain"
        )
        _ = try await store.record(
            station: station, artist: "Rick", title: "Real",
            youtubeID: "dQw4w9WgXcQ"
        )

        let radio = RadioBroadcaster(
            preferences: prefs, history: store, publishesPublicly: false
        )
        let rows = try Self.rows(from: await radio.buildHistoryPayload(path: "/history"))
        let byTitle = Dictionary(
            uniqueKeysWithValues: rows.compactMap { r -> (String, [String: Any])? in
                (r["title"] as? String).map { ($0, r) }
            }
        )

        let synthetic = try XCTUnwrap(byTitle["Synthetic"])
        XCTAssertTrue(
            synthetic["youtubeURL"] is NSNull,
            "a synthetic resolver id must not be dressed up as a watch URL"
        )
        XCTAssertTrue(
            synthetic["sourceURL"] is NSNull,
            "no source URL was recorded, and the key still says so"
        )
        XCTAssertEqual(
            Set(synthetic.keys), Set(byTitle["Real"]!.keys),
            "two rows in one payload must not have different key sets"
        )

        let real = try XCTUnwrap(byTitle["Real"])
        XCTAssertEqual(
            real["youtubeURL"] as? String,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "a real catalog id still becomes a link"
        )
    }

    /// A station object always carries `currentTrack` and `nextTrack`,
    /// even when there is nothing to put in them. A client comparing two
    /// stations in one payload should not see a different key set for each.
    @MainActor
    func testStationObjectsAlwaysCarryCurrentAndNextKeys() async throws {
        let prefs = BroadcastPreferences()
        prefs.port = 18_091
        defer { prefs.port = 18_000 }
        let radio = RadioBroadcaster(preferences: prefs, publishesPublicly: false)

        // A source that never resolves leaves both fields nil while the
        // pipeline stays up — exactly the case that used to drop the keys.
        // An EMPTY source won't do: it returns nil at once, the loop
        // unwinds, the last pipeline goes and the HTTP listener with it.
        let station = Station(name: "Silent", kind: .playlist(queue: []))
        await radio.startBroadcast(station: station, source: StallingSource())
        defer { radio.stopAll() }
        try await Task.sleep(nanoseconds: 500_000_000)

        let (data, _) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:18091/now.json")!
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let stations = try XCTUnwrap(json?["stations"] as? [[String: Any]])
        let only = try XCTUnwrap(stations.first)

        XCTAssertTrue(
            only.keys.contains("currentTrack"),
            "key must be present and null, not absent: \(only.keys.sorted())"
        )
        XCTAssertTrue(
            only.keys.contains("nextTrack"),
            "key must be present and null, not absent: \(only.keys.sorted())"
        )
        XCTAssertTrue(only["currentTrack"] is NSNull)
        XCTAssertTrue(only["nextTrack"] is NSNull)
    }

    /// Duration must describe the file being streamed, not a claim about
    /// it. A Bandcamp album download reports per-track durations for a
    /// playlist while the file on disk is one unidentified member of it —
    /// so a measured value overrides a reported one, and a missing
    /// measurement leaves the report alone.
    func testMeasuredDurationOverridesTheReportedOne() throws {
        let item = TrackSourceItem(
            url: URL(fileURLWithPath: "/tmp/x.m4a"),
            duration: 999, origin: .bandcamp
        )
        XCTAssertEqual(
            item.withProbedFile(artworkURL: nil, duration: 344.9).duration, 344.9
        )
        XCTAssertEqual(
            item.withProbedFile(artworkURL: nil, duration: nil).duration, 999,
            "no measurement means no opinion, not a wipe"
        )
        XCTAssertNil(
            TrackSourceItem(url: URL(fileURLWithPath: "/tmp/x.m4a"))
                .withProbedFile(artworkURL: nil, duration: nil).duration
        )
    }

    /// A listener who joins mid-track cannot infer how far in it is: the
    /// stream carries no position. `elapsedSeconds` is the only thing that
    /// tells them, and it is a delta rather than a start timestamp because
    /// a browser's clock can be minutes off a server's.
    func testElapsedSecondsIsMeasuredFromWhenTheTrackStarted() throws {
        let item = TrackSourceItem(
            url: URL(fileURLWithPath: "/tmp/x.m4a"),
            duration: 390, origin: .nts
        )
        let started = Date().addingTimeInterval(-42)
        let elapsed = try XCTUnwrap(
            RadioBroadcaster.NowTrack(item, startedAt: started).elapsedSeconds
        )
        XCTAssertEqual(elapsed, 42, accuracy: 1.0, "42 seconds in, and it says so")

        // Clamped to the track's own length: a station parked at a
        // boundary with no listener holds its last track as `current`, and
        // must not report it as more than finished.
        let overrun = try XCTUnwrap(
            RadioBroadcaster.NowTrack(item, startedAt: Date().addingTimeInterval(-9_000))
                .elapsedSeconds
        )
        XCTAssertEqual(overrun, 390, "never past the end of what it describes")

        // A track nobody measured cannot be clamped, but it can still be
        // counted — an unknown length is not an unknown position.
        let unmeasured = TrackSourceItem(url: URL(fileURLWithPath: "/tmp/y.m4a"), origin: .nts)
        let counted = try XCTUnwrap(
            RadioBroadcaster.NowTrack(unmeasured, startedAt: Date().addingTimeInterval(-10))
                .elapsedSeconds
        )
        XCTAssertEqual(counted, 10, accuracy: 1.0)

        // No start time is not a position of zero. Recent and upcoming
        // tracks are built this way, and a zero would invite a client to
        // render a clock for something silent.
        XCTAssertNil(
            RadioBroadcaster.NowTrack(item).elapsedSeconds,
            "a track that is not playing has no position"
        )
    }

    /// A decoder with nothing open has no duration to report, and must say
    /// so rather than returning zero — zero is a playing time.
    func testClosedDecoderReportsNoDuration() {
        XCTAssertNil(AudioDecoder().duration)
    }

    nonisolated static func rows(from payload: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return json?["entries"] as? [[String: Any]] ?? []
    }
}

/// A ``TrackSource`` that never produces a track and never gives up.
///
/// Models the real "resolving, slowly" state — a generative station whose
/// first pool fetch is still in flight — which is the only way to observe
/// a live pipeline with neither a current nor an upcoming track.
private actor StallingSource: TrackSource {
    func nextURL() async throws -> TrackSourceItem? {
        try await Task.sleep(nanoseconds: 600_000_000_000)
        return nil
    }
}
#endif
