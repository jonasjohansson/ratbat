import XCTest
@testable import JohanssoundCore

final class LibraryIndexerTests: XCTestCase {
    func testScanReturnsAllAudioFilesInFolder() async throws {
        let fixtureRoot = try locateFixtureFolder()
        let indexer = LibraryIndexer()
        let tracks = try await indexer.scan(folder: fixtureRoot)
        XCTAssertGreaterThanOrEqual(tracks.count, 2)
        let allowed: Set<String> = ["m4a", "mp3", "aac", "flac", "m4b", "wav", "aiff"]
        XCTAssertTrue(tracks.allSatisfy {
            allowed.contains($0.url.pathExtension.lowercased())
        })
    }

    func testScanIgnoresNonAudioFiles() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("johanssound-mix-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let fixtureRoot = try locateFixtureFolder()
        let anyM4A = try firstM4A(in: fixtureRoot)
        let copiedAudio = tempDir.appendingPathComponent("audio.m4a")
        try fm.copyItem(at: anyM4A, to: copiedAudio)

        try "not audio".write(
            to: tempDir.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )

        let tracks = try await LibraryIndexer().scan(folder: tempDir)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].url.pathExtension.lowercased(), "m4a")
    }

    func testScanUsesFilenameAsFallbackWhenMetadataMissing() async throws {
        let fixtureRoot = try locateFixtureFolder()
        let tracks = try await LibraryIndexer().scan(folder: fixtureRoot)
        XCTAssertFalse(tracks.isEmpty)
        for track in tracks {
            XCTAssertFalse(track.title.isEmpty)
            XCTAssertFalse(track.artist.isEmpty)
            XCTAssertFalse(track.album.isEmpty)
            // Fixtures have no common metadata, so artist/album must be the
            // fallback "Unknown" strings and title must be the filename.
            XCTAssertEqual(track.artist, "Unknown Artist")
            XCTAssertEqual(track.album, "Unknown Album")
            XCTAssertEqual(
                track.title,
                track.url.deletingPathExtension().lastPathComponent
            )
        }
    }

    // MARK: - Helpers

    private func locateFixtureFolder() throws -> URL {
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: "library", withExtension: nil, subdirectory: "Fixtures") {
            return url
        }
        if let url = bundle.url(forResource: "library", withExtension: nil) {
            return url
        }
        // Fallback: walk the bundle's resource directory looking for "library".
        if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("library")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let flatCandidate = resourceURL.appendingPathComponent("library")
            if FileManager.default.fileExists(atPath: flatCandidate.path) {
                return flatCandidate
            }
        }
        throw XCTSkip("Fixture folder not bundled — check project.yml test target resources")
    }

    private func firstM4A(in folder: URL) throws -> URL {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw XCTSkip("Couldn't enumerate fixture folder")
        }
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "m4a" {
            return url
        }
        throw XCTSkip("No m4a fixture found")
    }
}
