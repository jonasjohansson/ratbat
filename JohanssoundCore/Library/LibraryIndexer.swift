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

        // Common metadata — covers title/artist/album/genre on most files.
        let common = try await asset.load(.commonMetadata)
        let title = await firstStringValue(in: common, forKey: .commonKeyTitle)
        let artist = await firstStringValue(in: common, forKey: .commonKeyArtist)
        let album = await firstStringValue(in: common, forKey: .commonKeyAlbumName)
        var genre = await firstStringValue(in: common, forKey: .commonKeyType)

        // Full metadata — needed to pick up format-specific identifiers for
        // track number, year, and (some) genre tags that don't surface under
        // the `common*` keys.
        let allMetadata = try await asset.load(.metadata)
        let trackNumber = await parseTrackNumber(from: allMetadata)
        let year = await parseYear(from: allMetadata)
        if genre == nil {
            genre = await parseGenre(from: allMetadata)
        }

        // Bitrate: `estimatedDataRate` is bps. Convert to kbps; treat 0
        // (or non-finite) as "unknown".
        let bitrate = await loadBitrateKbps(for: asset)

        // File-system facts — these we can always read, independent of
        // whether metadata parsing succeeded.
        let (fileSize, dateAdded) = fileSystemAttributes(for: url)

        let filenameFallback = url.deletingPathExtension().lastPathComponent

        return Track(
            url: url,
            title: nonEmpty(title) ?? filenameFallback,
            artist: nonEmpty(artist) ?? "Unknown Artist",
            album: nonEmpty(album) ?? "Unknown Album",
            duration: duration,
            trackNumber: trackNumber,
            year: year,
            genre: nonEmpty(genre),
            bitrate: bitrate,
            fileSize: fileSize,
            dateAdded: dateAdded
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

    /// Extract a track number from ID3 `TRCK` (often shaped `"3/12"`) or
    /// the iTunes equivalent, returning just the leading integer.
    private func parseTrackNumber(from items: [AVMetadataItem]) async -> Int? {
        let candidates: [AVMetadataIdentifier] = [
            .id3MetadataTrackNumber,
            .iTunesMetadataTrackNumber
        ]
        for item in items where candidates.contains(item.identifier ?? .init(rawValue: "")) {
            // iTunes can store the track number as a numeric value; ID3
            // typically as a string like "3/12".
            if let number = try? await item.load(.numberValue) {
                return number.intValue
            }
            if let string = try? await item.load(.stringValue) {
                let head = string.split(separator: "/").first.map(String.init) ?? string
                if let n = Int(head.trimmingCharacters(in: .whitespaces)) {
                    return n
                }
            }
        }
        return nil
    }

    /// Year parsing looks across the handful of identifiers different
    /// tagging conventions use. We only need the 4-digit year even if the
    /// tag carries a full `YYYY-MM-DDTHH:MM:SS` timestamp.
    private func parseYear(from items: [AVMetadataItem]) async -> Int? {
        let candidates: [AVMetadataIdentifier] = [
            .id3MetadataYear,
            .id3MetadataReleaseTime,
            .id3MetadataRecordingTime,
            .id3MetadataOriginalReleaseYear,
            .iTunesMetadataReleaseDate,
            .commonIdentifierCreationDate
        ]
        for item in items where candidates.contains(item.identifier ?? .init(rawValue: "")) {
            if let number = try? await item.load(.numberValue) {
                let n = number.intValue
                if n >= 1000 && n <= 9999 { return n }
            }
            if let string = try? await item.load(.stringValue) {
                // Scan the first four consecutive digits as the year.
                var digits = ""
                for ch in string where ch.isNumber {
                    digits.append(ch)
                    if digits.count == 4 { break }
                }
                if digits.count == 4, let n = Int(digits) {
                    return n
                }
            }
        }
        return nil
    }

    /// Genre fallback when `commonKeyType` didn't yield anything — iTunes
    /// and ID3 both have their own genre identifiers.
    private func parseGenre(from items: [AVMetadataItem]) async -> String? {
        let candidates: [AVMetadataIdentifier] = [
            .id3MetadataContentType,
            .iTunesMetadataUserGenre,
            .iTunesMetadataPredefinedGenre
        ]
        for item in items where candidates.contains(item.identifier ?? .init(rawValue: "")) {
            if let string = try? await item.load(.stringValue),
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }
        return nil
    }

    /// Pull the audio track's `estimatedDataRate` and convert bps → kbps.
    /// Returns `nil` when no audio track exists or the data rate is
    /// non-positive (common on lossless/VBR files where AVFoundation
    /// reports 0).
    private func loadBitrateKbps(for asset: AVURLAsset) async -> Int? {
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        guard let rate = try? await audioTrack.load(.estimatedDataRate),
              rate.isFinite, rate > 0 else {
            return nil
        }
        return Int((rate / 1000).rounded())
    }

    /// Read file size and a sensible "added to library" date. `fileSize`
    /// falls back to 0 when the resource value is missing; `dateAdded`
    /// falls back through `.addedToDirectoryDate` → `.contentModificationDate`
    /// → "now" so we always return *something*.
    private func fileSystemAttributes(for url: URL) -> (Int64, Date) {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .addedToDirectoryDateKey,
            .contentModificationDateKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return (0, Date())
        }
        let size = Int64(values.fileSize ?? 0)
        let date = values.addedToDirectoryDate
            ?? values.contentModificationDate
            ?? Date()
        return (size, date)
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return s
    }
}
