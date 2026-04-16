import XCTest
@testable import JohanssoundCore

/// Spike-level tests for the Task 3.2 broadcast pipeline.
///
/// Unit testing a full `[Track] → PCM → AAC → HTTP → client` loop without
/// audio fixtures and network I/O in CI is a lot of ceremony for a spike,
/// so this file covers the pieces that are cheap to test in isolation:
/// - Initial state of ``RadioBroadcaster`` matches the documented
///   idle contract.
/// - ``ADTSHeader`` produces the documented 7-byte layout and the right
///   sync word so downstream clients can lock on.
/// - ``AACRingBuffer`` survives basic write / late-join-read cycles
///   without blocking or crashing.
final class RadioBroadcasterTests: XCTestCase {

    @MainActor
    func testRadioBroadcasterInitialState() async {
        let radio = RadioBroadcaster()
        XCTAssertFalse(radio.isBroadcasting)
        XCTAssertEqual(radio.listenerCount, 0)
        XCTAssertNil(radio.currentURL)
        XCTAssertNil(radio.error)
    }

    @MainActor
    func testStartWithEmptyQueueSurfacesError() async {
        let radio = RadioBroadcaster()
        await radio.start(queue: [])
        XCTAssertFalse(radio.isBroadcasting)
        XCTAssertNotNil(radio.error)
    }

    func testADTSHeaderConstruction() {
        let header = ADTSHeader(
            profile: 1,
            sampleFreqIdx: 4,
            channelConfig: 2,
            payloadLength: 300
        )
        let data = header.data
        XCTAssertEqual(data.count, 7)
        XCTAssertEqual(data[0], 0xFF)
        // High nibble of byte 1 is the sync-word tail; should still be 0xF*.
        XCTAssertEqual(data[1] & 0xF0, 0xF0)
        // Byte 2 low-bit tail = channelConfig >> 2 = 0 for stereo.
        // Byte 2 encodes profile<<6 | freqIdx<<2 | (chan>>2)
        XCTAssertEqual(data[2], (1 << 6) | (4 << 2) | (2 >> 2))
    }

    func testADTSSampleFrequencyIndexCommonRates() {
        XCTAssertEqual(ADTSHeader.sampleFrequencyIndex(for: 44_100), 4)
        XCTAssertEqual(ADTSHeader.sampleFrequencyIndex(for: 48_000), 3)
        XCTAssertEqual(ADTSHeader.sampleFrequencyIndex(for: 22_050), 7)
        XCTAssertNil(ADTSHeader.sampleFrequencyIndex(for: 12_345))
    }

    func testAACRingBufferReadFromLiveTail() async {
        // The documented "late-join" semantic: a fresh cursor starts at
        // the current write head. Old data is NOT replayed; a subsequent
        // write is what wakes readers.
        let buffer = AACRingBuffer(capacity: 1024)
        buffer.write(Data(repeating: 0xAB, count: 100))

        var cursor = buffer.readCursor()
        // New cursor = at write head, no data yet.
        // A write after the cursor is taken should be visible.
        buffer.write(Data(repeating: 0xCD, count: 50))

        let first = await buffer.read(from: &cursor)
        XCTAssertEqual(first.count, 50)
        XCTAssertEqual(first.first, 0xCD)
    }

    func testAACRingBufferCoalescesMultipleWrites() async {
        let buffer = AACRingBuffer(capacity: 1024)
        var cursor = buffer.readCursor()

        buffer.write(Data([0x01, 0x02]))
        buffer.write(Data([0x03, 0x04]))

        let data = await buffer.read(from: &cursor)
        // Both writes should be returned on one read (or at worst two
        // reads, but our tryRead always drains all available bytes).
        XCTAssertEqual(data, Data([0x01, 0x02, 0x03, 0x04]))
    }

    /// End-to-end pipeline smoke test. Fires up the broadcaster on a
    /// non-standard port (so we don't collide with a developer already
    /// poking port 8000), connects over TCP, sends a minimal GET, and
    /// verifies we get an HTTP 200 with `audio/aac` followed by at least
    /// one ADTS sync word (`0xFFF*`) in the body. Skips if the fixture
    /// tracks aren't bundled.
    ///
    /// This is the spike's KEY validation — if this test passes, the
    /// full `Track → PCM → AAC/ADTS → HTTP` chain works end-to-end with
    /// real fixture audio. Independently, running `ffprobe http://…` on
    /// a live broadcast (see `docs/spikes/radio-pipeline.md`) confirms a
    /// client-grade decoder also recognises the stream.
    @MainActor
    func testBroadcastProducesAACStream() async throws {
        let bundle = Bundle(for: RadioBroadcasterTests.self)
        guard let fixtureRoot = bundle.url(
            forResource: "library",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) ?? bundle.resourceURL?
            .appendingPathComponent("Fixtures/library") else {
            throw XCTSkip("Fixtures missing")
        }

        let playlists = try await LibraryIndexer().scan(folder: fixtureRoot)
        guard let tracks = playlists.first?.tracks, !tracks.isEmpty else {
            throw XCTSkip("No fixture tracks")
        }

        // Pick a port outside the default 8000 in case something else
        // is already bound.
        let port: UInt16 = 18_017
        let radio = RadioBroadcaster(port: port)
        await radio.start(queue: tracks)
        defer { radio.stop() }

        XCTAssertTrue(radio.isBroadcasting)

        // Give the encoder a moment to produce some bytes.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let (data, response) = try await Self.fetchStream(port: port, maxBytes: 8_192)

        guard let http = response as? HTTPURLResponse else {
            XCTFail("Not HTTP response")
            return
        }
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(
            (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
            "audio/aac"
        )

        // Look for an ADTS sync word in the payload. 0xFF 0xF1 means
        // "AAC frame start, MPEG-4, no CRC" which is what we emit.
        XCTAssertGreaterThan(data.count, 0)
        let syncFound = (0..<max(0, data.count - 1)).contains { i in
            data[i] == 0xFF && (data[i + 1] & 0xF6) == 0xF0
        }
        XCTAssertTrue(syncFound, "No ADTS sync word in \(data.count) bytes of stream")
    }

    /// Fetches up to `maxBytes` of a streaming HTTP URL. Uses a custom
    /// URLSession with a short timeout since the stream never ends on
    /// its own. Static so we can call it from a `@MainActor` test
    /// without dragging `self` across an actor hop (Swift 6 strict
    /// concurrency).
    nonisolated private static func fetchStream(
        port: UInt16,
        maxBytes: Int
    ) async throws -> (Data, URLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port)/stream.aac")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        let (bytes, response) = try await session.bytes(from: url)

        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
        } catch {
            // URLSession times out or cancels the stream — we just take
            // what we got.
        }
        return (data, response)
    }

    func testAACRingBufferOverflowBumpsCursor() async {
        // Buffer's minimum capacity is clamped to 1024, so to test the
        // overflow path we push ~3x that through and expect a slow
        // reader's cursor to be bumped forward to the freshest 1024
        // bytes. The exact byte values are 0..<N mod 256 (writing 3072
        // bytes means the last 1024 are bytes 2048..<3072 mod 256).
        let capacity = 1024
        let total = capacity * 3
        let buffer = AACRingBuffer(capacity: capacity)
        var cursor = buffer.readCursor()
        buffer.write(Data((0..<total).map { UInt8($0 & 0xFF) }))
        let data = await buffer.read(from: &cursor)
        XCTAssertEqual(data.count, capacity)
        XCTAssertEqual(data.first, UInt8(2048 & 0xFF))
        XCTAssertEqual(data.last, UInt8((total - 1) & 0xFF))
    }
}
