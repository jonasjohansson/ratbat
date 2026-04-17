import XCTest
@testable import RatbatCore

/// Unit tests for the ICY metadata block encoder. Verifies the wire
/// format: `[paddedLen/16][padded UTF-8 "StreamTitle='...';"]` with
/// NUL padding to a 16-byte boundary, the single-zero "no change"
/// short-circuit, and the single-quote / semicolon escapes that keep
/// the metadata delimiters unambiguous.
final class ICYMetadataTests: XCTestCase {

    func testICYMetadataEmptyBlockIsSingleZeroByte() {
        // Explicit `Track?` cast — two `block(for:trackChanged:)` overloads
        // exist now (Track, TrackSourceItem) and a bare `nil` is ambiguous.
        let data = ICYMetadata.block(for: nil as Track?, trackChanged: true)
        XCTAssertEqual(data, Data([0x00]))
    }

    func testICYMetadataTrackUnchangedIsZeroByte() {
        let track = Track(
            url: URL(fileURLWithPath: "/x.m4a"),
            title: "T",
            artist: "A",
            album: "L",
            duration: 100
        )
        let data = ICYMetadata.block(for: track, trackChanged: false)
        XCTAssertEqual(data, Data([0x00]))
    }

    func testICYMetadataTrackChangedEncodesTitle() {
        let track = Track(
            url: URL(fileURLWithPath: "/x.m4a"),
            title: "Hello",
            artist: "World",
            album: "L",
            duration: 100
        )
        let data = ICYMetadata.block(for: track, trackChanged: true)
        XCTAssertGreaterThan(data.count, 1)
        // First byte = length / 16
        let lengthByte = data[0]
        XCTAssertGreaterThan(lengthByte, 0)
        // Rest should decode to ASCII starting with StreamTitle=
        let meta = String(data: data.dropFirst(), encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        XCTAssertTrue(meta?.contains("StreamTitle='World - Hello';") == true)
        // Total length is multiple of 16 + 1 (the length byte)
        XCTAssertEqual((data.count - 1) % 16, 0)
        // Length byte accurately describes the payload.
        XCTAssertEqual(Int(lengthByte) * 16, data.count - 1)
    }

    func testICYMetadataEscapesSingleQuote() {
        let track = Track(
            url: URL(fileURLWithPath: "/x.m4a"),
            title: "It's",
            artist: "A",
            album: "L",
            duration: 100
        )
        let data = ICYMetadata.block(for: track, trackChanged: true)
        let meta = String(data: data.dropFirst(), encoding: .utf8) ?? ""
        XCTAssertFalse(meta.contains("It's"))
        XCTAssertTrue(meta.contains("It\u{2019}s"))  // curly apostrophe
    }

    func testICYMetadataEscapesSemicolon() {
        // Semicolons separate ICY fields, so they must be swapped so a
        // track called "One; Two" can't inject a second field.
        let track = Track(
            url: URL(fileURLWithPath: "/x.m4a"),
            title: "One; Two",
            artist: "A",
            album: "L",
            duration: 100
        )
        let data = ICYMetadata.block(for: track, trackChanged: true)
        let meta = String(data: data.dropFirst(), encoding: .utf8) ?? ""
        // Only one semicolon total, and it's the terminator.
        XCTAssertEqual(meta.filter { $0 == ";" }.count, 1)
        XCTAssertTrue(meta.contains("One: Two"))
    }

    func testICYMetadataClampsOverlongTitleToMaxPayload() {
        // 255 * 16 = 4080 is the absolute max we can describe in a
        // single length byte. We should never emit more than that.
        let long = String(repeating: "A", count: 10_000)
        let track = Track(
            url: URL(fileURLWithPath: "/x.m4a"),
            title: long,
            artist: long,
            album: "L",
            duration: 100
        )
        let data = ICYMetadata.block(for: track, trackChanged: true)
        XCTAssertLessThanOrEqual(data.count - 1, ICYMetadata.maxPayload)
        XCTAssertLessThanOrEqual(Int(data[0]), 255)
        // Still padded to a 16-byte multiple.
        XCTAssertEqual((data.count - 1) % 16, 0)
    }
}
