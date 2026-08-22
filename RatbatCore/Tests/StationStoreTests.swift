import XCTest
@testable import RatbatCore

/// Covers the versioned JSON envelope in ``StationStore`` with the same
/// shape of tests as ``CacheStoreTests`` — save/load round-trip, the three
/// standard failure modes (missing file, corrupt JSON, version mismatch),
/// and delete no-op semantics.
final class StationStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratbat-stationstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root = tempRoot {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testSaveAndLoadRoundTrip() throws {
        let track = Track(
            url: URL(fileURLWithPath: "/fake/a.m4a"),
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180
        )
        let station = Station(
            name: "Radio based on Jazz",
            kind: .playlist(queue: [track])
        )

        try StationStore.save([station], to: tempRoot)

        let expected = tempRoot.appendingPathComponent(".ratbat-stations.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))

        let loaded = try StationStore.load(from: tempRoot)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, station.id)
        XCTAssertEqual(loaded[0].name, "Radio based on Jazz")
        XCTAssertEqual(loaded[0].queue.count, 1)
        XCTAssertEqual(loaded[0].queue[0].title, "Song")
    }

    func testLoadFailsWhenNoFile() {
        XCTAssertThrowsError(try StationStore.load(from: tempRoot))
    }

    func testDeleteRemovesFile() throws {
        try StationStore.save([], to: tempRoot)
        XCTAssertNoThrow(try StationStore.load(from: tempRoot))
        try StationStore.delete(from: tempRoot)
        XCTAssertThrowsError(try StationStore.load(from: tempRoot))
    }

    func testDeleteIsNoopWhenMissing() throws {
        XCTAssertNoThrow(try StationStore.delete(from: tempRoot))
    }

    func testLoadFailsOnVersionMismatch() throws {
        let url = tempRoot.appendingPathComponent(".ratbat-stations.json")
        let garbage = """
        {"version": 999, "stations": []}
        """.data(using: .utf8)!
        try garbage.write(to: url)

        XCTAssertThrowsError(try StationStore.load(from: tempRoot)) { error in
            guard let storeError = error as? StationStore.StationError else {
                XCTFail("Expected StationStore.StationError, got \(error)")
                return
            }
            XCTAssertEqual(storeError, .versionMismatch)
        }
    }

    func testLoadFailsOnCorruptData() throws {
        let url = tempRoot.appendingPathComponent(".ratbat-stations.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try StationStore.load(from: tempRoot))
    }

    /// A `.ratbat-stations.json` file shared across machines (e.g. via
    /// Google Drive) may contain entries this build can't decode —
    /// a `.bandcamp` station authored on macOS read by an iOS build,
    /// or a future station kind seen by an older binary. Previously
    /// those caused the whole decode to throw and the caller wiped the
    /// entire station list. After the fix, each unreadable entry is
    /// logged + skipped and the survivors come back intact.
    func testLoadSkipsUndecodableStationEntries() throws {
        // Encode two fully-valid playlist stations the normal way so we
        // don't have to hand-craft the Swift-synthesised enum JSON.
        let trackA = Track(
            url: URL(fileURLWithPath: "/fake/a.m4a"),
            title: "A",
            artist: "ArtistA",
            album: "AlbumA",
            duration: 120
        )
        let trackB = Track(
            url: URL(fileURLWithPath: "/fake/b.m4a"),
            title: "B",
            artist: "ArtistB",
            album: "AlbumB",
            duration: 180
        )
        let stationA = Station(name: "Alpha", kind: .playlist(queue: [trackA]))
        let stationB = Station(name: "Beta", kind: .playlist(queue: [trackB]))

        let encoder = JSONEncoder()
        let dataA = try encoder.encode(stationA)
        let dataB = try encoder.encode(stationB)
        let objA = try JSONSerialization.jsonObject(with: dataA)
        let objB = try JSONSerialization.jsonObject(with: dataB)

        // Shove in two entries this build can't decode: an outright
        // garbage blob, and an object pretending to be a station with
        // an unknown kind. Swift synthesised enum coding keys the enum
        // by variant name, so a made-up one won't match any case.
        let garbage: [String: Any] = ["nope": "totally not a station"]
        let unknownKind: [String: Any] = [
            "id": UUID().uuidString,
            "name": "From The Future",
            "kind": ["futureKind": ["_0": ["foo": "bar"]]]
        ]

        let envelope: [String: Any] = [
            "version": 1,
            "stations": [objA, garbage, objB, unknownKind]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let url = tempRoot.appendingPathComponent(".ratbat-stations.json")
        try data.write(to: url)

        let loaded = try StationStore.load(from: tempRoot)
        XCTAssertEqual(loaded.count, 2, "Expected 2 decodable stations to survive; garbage + unknown-kind entries should be skipped.")
        let names = Set(loaded.map(\.name))
        XCTAssertEqual(names, ["Alpha", "Beta"])
    }

    /// The S4 forward-compat requirement, proven rather than asserted:
    /// an OLDER build (which has no `.libraryRadio` case) reading a
    /// stations file that contains a libraryRadio entry must NOT wipe
    /// the file. This build *does* know the kind, so the old build is
    /// simulated the only honest way available in-process: a fixture
    /// entry whose `kind` key is one this binary cannot decode, with a
    /// payload shaped exactly like a libraryRadio config. The mechanism
    /// under test — ``StationStore``'s per-entry fail-open decode — is
    /// the very one the old binary relies on, so what this test proves
    /// for `veryFutureKind` holds for `libraryRadio` on origin/main.
    ///
    /// Outcome, stated exactly (and mirrored in docs/mac-mini-setup.md):
    /// - **Read is safe.** The unknown entry is logged + skipped; every
    ///   sibling loads; the file on disk is untouched by reading.
    /// - **Write-back is lossy.** `save` encodes the reduced in-memory
    ///   list, so an old build that *mutates* stations drops the kinds
    ///   it doesn't know. Preserving undecoded entries would mean
    ///   carrying raw JSON blobs through `[Station]` — not achievable
    ///   cheaply — so the loss is the documented single-writer posture
    ///   (the Mini is authoritative; other machines reflect read-only),
    ///   and this test pins the actual behavior instead of wishing it
    ///   away.
    func testUnknownKindEntrySurvivesReadButIsDroppedByWriteBack() throws {
        let known = Station(name: "Known Sibling", kind: .playlist(queue: []))
        let knownJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(known)
        )
        // Byte-for-byte the shape a future kind writes: synthesized enum
        // coding nests the config under kind.<caseName>.config — the same
        // envelope `.libraryRadio` uses on the wire today.
        let futureEntry: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Whole Library",
            "kind": ["veryFutureKind": ["config": [
                "id": UUID().uuidString,
                "name": "Whole Library",
                "query": [
                    "genreTags": ["ambient"], "yearMin": NSNull(),
                    "yearMax": NSNull(), "regions": [],
                    "tagMatch": "any", "popularity": "middle",
                    "excludeOwnedLibrary": false, "excludedArtists": []
                ] as [String: Any],
                "shufflePool": true
            ] as [String: Any]]]
        ]
        let envelope: [String: Any] = [
            "version": StationStore.currentVersion,
            "stations": [knownJSON, futureEntry]
        ]
        let url = tempRoot.appendingPathComponent(StationStore.filename)
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)

        // Read: the sibling survives, the unknown entry is dropped, and
        // the bytes on disk still hold BOTH entries — loading is not a
        // write.
        let loaded = try StationStore.load(from: tempRoot)
        XCTAssertEqual(loaded.map(\.name), ["Known Sibling"],
                       "siblings must survive an unknown kind")
        let onDiskAfterRead = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDiskAfterRead.contains("veryFutureKind"),
                      "reading must never rewrite the file")

        // Write-back: persisting the reduced list loses the unknown
        // entry. This is the ACTUAL behavior — asserted, not accidental —
        // and the reason mac-mini-setup.md tells every non-Mini machine
        // to stay a reader.
        try StationStore.save(loaded, to: tempRoot)
        let onDiskAfterSave = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDiskAfterSave.contains("veryFutureKind"),
                       "write-back is lossy for unknown kinds (documented single-writer posture)")
        XCTAssertTrue(onDiskAfterSave.contains("Known Sibling"))
    }

    /// The libraryRadio wire shape, pinned: this build round-trips a
    /// `.libraryRadio` station through the store with the kind spelled
    /// `libraryRadio` and the envelope still at version 1 (bumping it is
    /// what would make old builds wipe the file — see risk R2).
    func testLibraryRadioStationRoundTripsUnderVersionOne() throws {
        let config = LibraryRadioStationConfig(
            name: "Home Tapes",
            query: FacetedQuery(genreTags: ["ambient"], yearMin: 1990),
            shufflePool: false
        )
        let station = Station.fromLibraryRadio(config)
        try StationStore.save([station], to: tempRoot)

        let url = tempRoot.appendingPathComponent(StationStore.filename)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"libraryRadio\""), "wire kind key is the synthesized case name")
        XCTAssertTrue(raw.contains("\"version\":1"), "the envelope must stay at v1 — a bump wipes old builds")

        let loaded = try StationStore.load(from: tempRoot)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, config.id, "station id reuses the config id (history-dedup invariant)")
        XCTAssertEqual(loaded[0].libraryRadioConfig, config)
    }

    /// Envelope itself is wrong — no `version` key at all — so we bail
    /// with the dedicated corruptEnvelope error rather than silently
    /// returning an empty list.
    func testLoadRejectsEnvelopeMissingVersion() throws {
        let url = tempRoot.appendingPathComponent(".ratbat-stations.json")
        try Data(#"{"stations": []}"#.utf8).write(to: url)

        XCTAssertThrowsError(try StationStore.load(from: tempRoot)) { error in
            guard let storeError = error as? StationStore.StationError else {
                XCTFail("Expected StationStore.StationError, got \(error)")
                return
            }
            XCTAssertEqual(storeError, .corruptEnvelope)
        }
    }
}

extension StationStore.StationError: Equatable {
    public static func == (lhs: StationStore.StationError, rhs: StationStore.StationError) -> Bool {
        switch (lhs, rhs) {
        case (.versionMismatch, .versionMismatch): return true
        case (.corruptEnvelope, .corruptEnvelope): return true
        default: return false
        }
    }
}
