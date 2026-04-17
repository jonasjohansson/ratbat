import Foundation

/// ICY (Shoutcast) metadata block encoding.
///
/// The ICY protocol injects per-client metadata blocks into an otherwise
/// pure audio stream every `icy-metaint` bytes. Block layout:
/// `[UInt8: length/16][length bytes: padded metadata string]`
///
/// The first byte is a count where `byte * 16` equals the number of metadata
/// bytes that follow. A leading `0x00` means "no metadata changed since
/// last block" and is the standard keep-alive. The metadata string is
/// conventionally `StreamTitle='Artist - Title';` padded to a 16-byte
/// boundary with NUL bytes.
///
/// Max payload is 255 * 16 = 4080 bytes — anything longer is clamped so we
/// never need a second byte.
enum ICYMetadata {
    /// Number of audio bytes between metadata blocks. 16384 (16 KiB) is the
    /// de-facto default that every ICY-aware client we've tested (VLC,
    /// Apple Music, Winamp) understands.
    static let blockInterval = 16_384

    /// Maximum metadata payload in bytes (255 * 16).
    static let maxPayload = 4_080

    /// Build metadata bytes for an ICY block.
    /// - If `trackChanged == false`, returns `Data([0x00])` — the "no
    ///   change" keep-alive the spec recommends we emit every interval to
    ///   keep client-side buffers in sync.
    /// - Otherwise returns `[paddedLen/16] + "StreamTitle='Artist - Title';"`
    ///   padded to a multiple of 16 bytes with NULs.
    ///
    /// A `nil` track also yields `Data([0x00])` — the station is idle, so
    /// there's nothing to announce even if we "changed".
    static func block(for track: Track?, trackChanged: Bool) -> Data {
        guard trackChanged, let track else { return Data([0x00]) }
        let title = escape("\(track.artist) - \(track.title)")
        let payload = "StreamTitle='\(title)';"
        var bytes = Array(payload.utf8)
        // Clamp to 4080 bytes max (255 * 16) so the length byte fits in UInt8.
        if bytes.count > maxPayload { bytes = Array(bytes.prefix(maxPayload)) }
        // Pad to next multiple of 16 with NULs.
        let paddedLen = ((bytes.count + 15) / 16) * 16
        while bytes.count < paddedLen { bytes.append(0) }
        let lengthByte = UInt8(paddedLen / 16)
        return Data([lengthByte]) + Data(bytes)
    }

    /// ICY uses single quotes as string delimiters in the metadata payload
    /// and semicolons to separate fields. We swap them for visually similar
    /// characters rather than trying to escape, because most clients don't
    /// handle escapes and will render the raw bytes either way.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "\u{2019}")   // right single quote
         .replacingOccurrences(of: ";", with: ":")
    }
}
