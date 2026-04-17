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
            seed: .playlist(sourceID: UUID(), sourceName: "Jazz"),
            queue: [track]
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
}

extension StationStore.StationError: Equatable {
    public static func == (lhs: StationStore.StationError, rhs: StationStore.StationError) -> Bool {
        switch (lhs, rhs) {
        case (.versionMismatch, .versionMismatch): return true
        }
    }
}
