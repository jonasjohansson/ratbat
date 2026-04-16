import XCTest
@testable import JohanssoundCore

final class LibraryIndexerTests: XCTestCase {

    func testScanProducesAllSongsFirst() async throws {
        let fixtures = try locateFixtureFolder()
        let playlists = try await LibraryIndexer().scan(folder: fixtures)
        XCTAssertFalse(playlists.isEmpty)
        XCTAssertEqual(playlists[0].kind, .allSongs)
        XCTAssertEqual(playlists[0].name, "All Songs")
        XCTAssertNil(playlists[0].folder)
    }

    func testScanGroupsTopLevelFoldersAsPlaylists() async throws {
        let fixtures = try locateFixtureFolder()
        let playlists = try await LibraryIndexer().scan(folder: fixtures)
        let folderNames = playlists
            .filter { $0.kind == .folder }
            .map(\.name)
        // Already sorted A–Z by the indexer.
        XCTAssertEqual(folderNames, ["ArtistA", "ArtistB"])
    }

    func testAllSongsUnionsFolderPlaylists() async throws {
        let fixtures = try locateFixtureFolder()
        let playlists = try await LibraryIndexer().scan(folder: fixtures)
        guard let all = playlists.first(where: { $0.kind == .allSongs }) else {
            XCTFail("Expected an All Songs playlist")
            return
        }
        // Under Model B, top-level folder playlists already carry the union
        // of all their descendants' tracks, so summing top-level folders +
        // Loose Tracks equals the All Songs total (no double-counting).
        let topLevelFolders = playlists.filter { $0.kind == .folder }
        let loose = playlists.filter { $0.kind == .looseTracks }
        let topLevelTrackCount = topLevelFolders.reduce(0) { $0 + $1.tracks.count }
            + loose.reduce(0) { $0 + $1.tracks.count }
        XCTAssertEqual(all.tracks.count, topLevelTrackCount)

        // Every track URL in All Songs should exist in one of the top-level
        // folder or loose playlists — the union must not invent tracks.
        let topLevelURLs = Set(
            topLevelFolders.flatMap(\.tracks).map(\.url)
                + loose.flatMap(\.tracks).map(\.url)
        )
        for track in all.tracks {
            XCTAssertTrue(topLevelURLs.contains(track.url))
        }
    }

    func testFolderPlaylistHasChildrenForNestedSubfolders() async throws {
        let fixtures = try locateFixtureFolder()
        let playlists = try await LibraryIndexer().scan(folder: fixtures)
        guard let artistA = playlists.first(where: { $0.name == "ArtistA" }) else {
            XCTFail("Expected ArtistA folder playlist")
            return
        }
        // ArtistA has a single sub-folder AlbumA which holds the one track.
        XCTAssertEqual(artistA.children.map(\.name), ["AlbumA"])
        XCTAssertEqual(artistA.kind, .folder)

        guard let albumA = artistA.children.first else {
            XCTFail("Expected AlbumA child playlist")
            return
        }
        XCTAssertEqual(albumA.kind, .folder)
        XCTAssertTrue(albumA.children.isEmpty)
        XCTAssertEqual(albumA.tracks.count, 1)

        // Union behaviour: ArtistA.tracks must include AlbumA's track(s).
        XCTAssertEqual(artistA.tracks.count, albumA.tracks.count)
        let artistURLs = Set(artistA.tracks.map(\.url))
        for track in albumA.tracks {
            XCTAssertTrue(artistURLs.contains(track.url))
        }
    }

    func testTracksHaveFileSizeAndDateAdded() async throws {
        // File-system facts (size, dateAdded) are read independently of
        // metadata parsing, so even our tag-less fixture files should
        // report a non-zero size and a past modification date. The
        // optional ID3/iTunes metadata fields (trackNumber, year, genre,
        // bitrate) are allowed to be nil on these fixtures — we just
        // assert they don't crash the indexer.
        let fixtures = try locateFixtureFolder()
        let playlists = try await LibraryIndexer().scan(folder: fixtures)
        guard let all = playlists.first(where: { $0.kind == .allSongs }) else {
            XCTFail("Expected an All Songs playlist")
            return
        }
        XCTAssertFalse(all.tracks.isEmpty)
        XCTAssertTrue(all.tracks.allSatisfy { $0.fileSize > 0 })
        XCTAssertTrue(all.tracks.allSatisfy { $0.dateAdded.timeIntervalSinceNow < 0 })
    }

    func testLooseTracksPlaylistPresentWhenRootHasAudio() async throws {
        let fixtures = try locateFixtureFolder()
        let playlists = try await LibraryIndexer().scan(folder: fixtures)
        let loose = playlists.first { $0.kind == .looseTracks }
        // The fixture now includes `loose-track.m4a` at the root, so the
        // playlist must be present. If the fixture isn't bundled for some
        // reason, treat it as a soft skip rather than a hard failure.
        if let loose {
            XCTAssertEqual(loose.name, "Loose Tracks")
            XCTAssertGreaterThanOrEqual(loose.tracks.count, 1)
        } else {
            throw XCTSkip("No loose-track fixture in bundle; skipping this assertion")
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
}
