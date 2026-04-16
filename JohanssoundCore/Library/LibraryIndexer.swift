import Foundation
import AVFoundation
import os

/// Recursively scans a folder for audio files and produces `Track` records
/// with metadata extracted via AVFoundation.
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

    /// Scan `folder` recursively and return every audio file as a `Track`,
    /// sorted by artist → album → title (case-insensitive).
    ///
    /// Files whose metadata can't be loaded are logged and skipped; they
    /// never fail the whole scan. That's the right trade-off for a local
    /// library: one corrupt file shouldn't hide the other 9,999.
    public func scan(folder: URL) async throws -> [Track] {
        let urls = enumerateAudioFiles(under: folder)

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

    // MARK: - Private

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
