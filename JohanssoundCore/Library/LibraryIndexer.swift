import Foundation
import AVFoundation
import os

/// Scans a music-library folder and groups tracks into ``Playlist`` values.
///
/// Top-level subfolders of the root each become a folder-kind playlist.
/// Audio files sitting directly in the root are collected into a single
/// "Loose Tracks" playlist (omitted if none exist). A synthetic "All Songs"
/// playlist — the union of every track — is always included first.
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
    /// folder-kind playlists sorted A–Z case-insensitively.
    ///
    /// Files whose metadata can't be loaded are logged and skipped; they
    /// never fail the whole scan. That's the right trade-off for a local
    /// library: one corrupt file shouldn't hide the other 9,999.
    public func scan(folder root: URL) async throws -> [Playlist] {
        let fm = FileManager.default

        // Use `contentsOfDirectory` (non-recursive) for the first-level
        // folder-vs-file decision, then recurse inside each subfolder.
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

        var folderPlaylists: [Playlist] = []
        var looseURLs: [URL] = []

        for url in topLevel {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                let tracks = await scanAudioFiles(in: url)
                // Even empty subfolders become playlists — users can drop
                // files in later and the group is still "theirs". If that
                // feels wrong in practice we can flip this to skip empties.
                folderPlaylists.append(
                    Playlist(
                        name: url.lastPathComponent,
                        folder: url,
                        tracks: tracks,
                        kind: .folder
                    )
                )
            } else if values?.isRegularFile == true,
                      Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                looseURLs.append(url)
            }
        }

        folderPlaylists.sort {
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
                kind: .looseTracks
            )
        }

        // All Songs = every folder playlist's tracks + loose tracks, in
        // enumeration order. Global sorting (by artist/title etc.) belongs
        // in UI-level sort controls — that's Task 1.10.
        var allTracks: [Track] = []
        for playlist in folderPlaylists { allTracks.append(contentsOf: playlist.tracks) }
        if let loose = loosePlaylist { allTracks.append(contentsOf: loose.tracks) }
        let allSongs = Playlist(
            name: "All Songs",
            folder: nil,
            tracks: allTracks,
            kind: .allSongs
        )

        var result: [Playlist] = [allSongs]
        if let loose = loosePlaylist { result.append(loose) }
        result.append(contentsOf: folderPlaylists)
        return result
    }

    // MARK: - Private

    /// Recursively enumerate audio files under `folder`, load metadata, and
    /// return tracks sorted by artist → album → title (case-insensitive).
    private func scanAudioFiles(in folder: URL) async -> [Track] {
        let urls = enumerateAudioFiles(under: folder)
        return await makeSortedTracks(from: urls)
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

    private func enumerateAudioFiles(under folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard Self.audioExtensions.contains(ext) else { continue }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            results.append(url)
        }
        return results
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
