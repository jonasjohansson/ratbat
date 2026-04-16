import Foundation
import AVFoundation
import os

/// Scans a music-library folder and groups tracks into ``Playlist`` values.
///
/// **Model B — hierarchical folders:** every folder at any depth becomes a
/// playlist. A folder playlist's ``Playlist/tracks`` is the *union* of every
/// audio file discovered under it (direct children plus everything beneath
/// each sub-folder), and its ``Playlist/children`` holds the direct
/// sub-folder playlists so the sidebar can render the tree. Audio files
/// sitting directly in the root are collected into a single "Loose Tracks"
/// playlist (omitted if none exist). A synthetic "All Songs" playlist — the
/// union of every track — is always included first.
///
/// v1 walks files sequentially. That's slower than `TaskGroup`-based
/// parallelism, but it's also simple, avoids I/O contention on spinning
/// disks and network shares, and is trivially correct. Parallelism can be
/// layered on in a later task if scan time ever becomes a felt problem.
///
/// `Sendable` because the type holds no state — callers can freely hand it
/// across actor boundaries.
public struct LibraryIndexer: Sendable {
    /// Extensions we treat as audio. Everything else in the folder is
    /// ignored, so a user's album-art JPEGs and lyric .txt files won't
    /// pollute the library.
    private static let audioExtensions: Set<String> = [
        "m4a", "mp3", "aac", "flac", "m4b", "wav", "aiff"
    ]

    private static let log = Logger(
        subsystem: "se.jonasjohansson.johanssound.core",
        category: "LibraryIndexer"
    )

    public init() {}

    /// Scan `root` and return the resulting playlists.
    ///
    /// Order: "All Songs" first, then "Loose Tracks" (if any), then
    /// top-level folder-kind playlists sorted A–Z case-insensitively. Each
    /// folder playlist carries its own sub-folders in ``Playlist/children``,
    /// which the sidebar renders recursively.
    ///
    /// Files whose metadata can't be loaded are logged and skipped; they
    /// never fail the whole scan. That's the right trade-off for a local
    /// library: one corrupt file shouldn't hide the other 9,999.
    public func scan(folder root: URL) async throws -> [Playlist] {
        let fm = FileManager.default

        // First-level split: files vs folders at the root.
        let topLevel: [URL]
        do {
            topLevel = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // A missing/unreadable root is surfaced as "no playlists" rather
            // than a throw — the previous behaviour of the indexer when the
            // deep enumerator returned nil. This keeps the view model's
            // error UI focused on real failures (e.g. metadata parse errors).
            Self.log.warning(
                "Couldn't read \(root.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }

        var topLevelFolderURLs: [URL] = []
        var looseURLs: [URL] = []

        for url in topLevel {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                topLevelFolderURLs.append(url)
            } else if values?.isRegularFile == true,
                      Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                looseURLs.append(url)
            }
        }

        // Build folder playlists recursively, one per top-level subfolder.
        var topLevelPlaylists: [Playlist] = []
        for url in topLevelFolderURLs {
            let playlist = await buildFolderPlaylist(at: url)
            topLevelPlaylists.append(playlist)
        }
        topLevelPlaylists.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        // Build loose-tracks playlist only if we actually have loose audio.
        var loosePlaylist: Playlist?
        if !looseURLs.isEmpty {
            let looseTracks = await makeSortedTracks(from: looseURLs)
            loosePlaylist = Playlist(
                name: "Loose Tracks",
                folder: root,
                tracks: looseTracks,
                children: [],
                kind: .looseTracks
            )
        }

        // All Songs = every folder playlist's (already union-ed) tracks +
        // loose tracks. Because each folder's `.tracks` is already the union
        // of its descendants, summing the top-level folders is enough to
        // cover the whole tree.
        var allTracks: [Track] = []
        for playlist in topLevelPlaylists { allTracks.append(contentsOf: playlist.tracks) }
        if let loose = loosePlaylist { allTracks.append(contentsOf: loose.tracks) }
        let allSongs = Playlist(
            name: "All Songs",
            folder: nil,
            tracks: allTracks,
            children: [],
            kind: .allSongs
        )

        var result: [Playlist] = [allSongs]
        if let loose = loosePlaylist { result.append(loose) }
        result.append(contentsOf: topLevelPlaylists)
        return result
    }

    // MARK: - Private

    /// Recursively build a folder playlist for `url`.
    ///
    /// The returned playlist:
    /// - ``Playlist/children`` — direct sub-folder playlists, sorted A–Z.
    /// - ``Playlist/tracks`` — union of direct audio files (sorted by
    ///   artist/album/title) followed by each child's tracks in child
    ///   order. That gives us a deterministic ordering without trying to
    ///   globally re-sort across the union; the UI's column-sort controls
    ///   can re-sort as the user wishes.
    private func buildFolderPlaylist(at url: URL) async -> Playlist {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Self.log.warning(
                "Couldn't read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return Playlist(
                name: url.lastPathComponent,
                folder: url,
                tracks: [],
                children: [],
                kind: .folder
            )
        }

        var directAudioURLs: [URL] = []
        var subfolderURLs: [URL] = []
        for childURL in contents {
            let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                subfolderURLs.append(childURL)
            } else if values?.isRegularFile == true,
                      Self.audioExtensions.contains(childURL.pathExtension.lowercased()) {
                directAudioURLs.append(childURL)
            }
        }

        // Recurse into sub-folders. Sequential — recursive async in a
        // TaskGroup would complicate error handling for no obvious win on a
        // normally-sized local library. Easy to revisit later.
        var children: [Playlist] = []
        children.reserveCapacity(subfolderURLs.count)
        for subURL in subfolderURLs {
            let child = await buildFolderPlaylist(at: subURL)
            children.append(child)
        }
        children.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let directTracks = await makeSortedTracks(from: directAudioURLs)

        // Union: this folder's own files + every descendant's tracks (which
        // are themselves already unioned, so this one-level concat covers
        // the full subtree).
        var unionTracks: [Track] = directTracks
        for child in children {
            unionTracks.append(contentsOf: child.tracks)
        }

        return Playlist(
            name: url.lastPathComponent,
            folder: url,
            tracks: unionTracks,
            children: children,
            kind: .folder
        )
    }

    private func makeSortedTracks(from urls: [URL]) async -> [Track] {
        var tracks: [Track] = []
        tracks.reserveCapacity(urls.count)

        for url in urls {
            do {
                let track = try await makeTrack(for: url)
                tracks.append(track)
            } catch {
                Self.log.warning(
                    "Skipping \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return tracks.sorted { lhs, rhs in
            let a = lhs.artist.localizedCaseInsensitiveCompare(rhs.artist)
            if a != .orderedSame { return a == .orderedAscending }
            let b = lhs.album.localizedCaseInsensitiveCompare(rhs.album)
            if b != .orderedSame { return b == .orderedAscending }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func makeTrack(for url: URL) async throws -> Track {
        let asset = AVURLAsset(url: url)

        let durationValue = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(durationValue)
        let duration = seconds.isFinite ? seconds : 0

        let metadata = try await asset.load(.commonMetadata)
        let title = await firstStringValue(in: metadata, forKey: .commonKeyTitle)
        let artist = await firstStringValue(in: metadata, forKey: .commonKeyArtist)
        let album = await firstStringValue(in: metadata, forKey: .commonKeyAlbumName)

        let filenameFallback = url.deletingPathExtension().lastPathComponent

        return Track(
            url: url,
            title: nonEmpty(title) ?? filenameFallback,
            artist: nonEmpty(artist) ?? "Unknown Artist",
            album: nonEmpty(album) ?? "Unknown Album",
            duration: duration
        )
    }

    private func firstStringValue(
        in items: [AVMetadataItem],
        forKey key: AVMetadataKey
    ) async -> String? {
        for item in items where item.commonKey == key {
            // In this SDK, `.stringValue` on an AVMetadataItem async property
            // loads to a non-optional `String`; `try?` wraps it in `String?`.
            if let value = try? await item.load(.stringValue) {
                return value
            }
        }
        return nil
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return s
    }
}
