import Foundation
import AVFoundation
import CryptoKit

/// Reads the metadata a local audio file carries in its own tags.
///
/// Everything the broadcaster streams — a library file, or a transient
/// download the resolver just made — is a local decodable file by the time
/// it reaches the encode loop. That makes the file itself the one place
/// every source has in common, which is why cover art is pulled from here
/// rather than plumbed separately through four different controllers.
///
/// Deliberately narrow: the library indexer already parses album / duration
/// / year into ``Track`` at scan time, so this type only covers what the
/// indexer does NOT keep — the artwork bytes, which are far too big to hold
/// for every track in a library.
public enum TrackFileProbe {

    /// Stable, short, filesystem- and URL-safe handle for a file's artwork.
    ///
    /// Derived from the file path rather than the image bytes so the id can
    /// be computed without reading the image — the recent ring needs an id
    /// for tracks whose bytes may already have aged out of the cache.
    public static func artworkID(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Embedded cover art as JPEG bytes, or `nil` when the file carries
    /// none.
    ///
    /// Returns `nil` rather than a placeholder on every failure path — an
    /// unreadable file, an art-less file, or an image we can't transcode all
    /// mean the same thing to a client: there is nothing to show. Non-JPEG
    /// embedded art (PNG is common in iTunes-tagged files) is re-encoded so
    /// the HTTP route can advertise one content type.
    public static func artworkJPEG(of url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        let artworkItems = AVMetadataItem.metadataItems(
            from: items, filteredByIdentifier: .commonIdentifierArtwork
        )
        for item in artworkItems {
            guard let data = try? await item.load(.dataValue), !data.isEmpty else {
                continue
            }
            if isJPEG(data) { return data }
            if let transcoded = transcodeToJPEG(data) { return transcoded }
        }
        return nil
    }

    /// JPEG files start with the SOI marker `FF D8 FF`. Cheap enough to
    /// check that it isn't worth decoding an image to find out.
    private static func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data[data.startIndex] == 0xFF
            && data[data.startIndex + 1] == 0xD8
            && data[data.startIndex + 2] == 0xFF
    }

    private static func transcodeToJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
