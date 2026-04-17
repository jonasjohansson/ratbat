import Foundation

/// 7-byte ADTS header prepended to each raw AAC frame so the resulting
/// byte stream is self-describing and playable by VLC / ffplay / most
/// browsers over `audio/aac`. Without ADTS headers, raw AAC from
/// AudioConverter is just payload with no sync word — clients have no way
/// to find frame boundaries.
///
/// Header layout (MPEG-4, no CRC):
/// ```
/// byte 0: 0xFF                                      sync word (high)
/// byte 1: 0xF1                                      sync (low) + MPEG-4 + no CRC
/// byte 2: profile<<6 | sampleFreqIdx<<2 | chanCfg>>2
/// byte 3: (chanCfg & 3)<<6 | frameLen>>11
/// byte 4: (frameLen >> 3) & 0xFF
/// byte 5: (frameLen & 7)<<5 | 0x1F                  buffer fullness (high)
/// byte 6: 0xFC                                      buffer fullness (low) + RDB=0
/// ```
/// where `frameLen = 7 + payloadLength`.
///
/// Reference: ISO/IEC 13818-7 §5.2 (ADTS frame), and the classic
/// wiki.multimedia.cx writeup.
struct ADTSHeader: Equatable, Sendable {
    let profile: UInt8          // 1 = AAC LC (the MPEG-4 audio object type)
    let sampleFreqIdx: UInt8    // 4 = 44100, 3 = 48000, etc.
    let channelConfig: UInt8    // 2 = stereo
    let payloadLength: Int      // AAC frame bytes (without the ADTS header)

    var data: Data {
        // Spec: the "profile" bits in the ADTS header are
        // `MPEG-4 Audio Object Type - 1`. AAC LC is AOT 2, so the bits
        // here are 1. Caller is expected to already subtract — we
        // store whatever was passed and trust the caller.
        let frameLength = 7 + payloadLength
        var bytes = [UInt8](repeating: 0, count: 7)
        bytes[0] = 0xFF
        bytes[1] = 0xF1
        bytes[2] = ((profile & 0x03) << 6)
            | ((sampleFreqIdx & 0x0F) << 2)
            | ((channelConfig & 0x07) >> 2)
        bytes[3] = ((channelConfig & 0x03) << 6)
            | UInt8((frameLength >> 11) & 0x03)
        bytes[4] = UInt8((frameLength >> 3) & 0xFF)
        bytes[5] = UInt8((frameLength & 0x07) << 5) | 0x1F
        bytes[6] = 0xFC
        return Data(bytes)
    }

    /// Helper: map a common sample rate to its ADTS index. Returns `nil`
    /// for a rate outside the ADTS table — the caller should fall back
    /// to a supported rate or bail out of the broadcast.
    static func sampleFrequencyIndex(for sampleRate: Double) -> UInt8? {
        switch Int(sampleRate) {
        case 96_000: return 0
        case 88_200: return 1
        case 64_000: return 2
        case 48_000: return 3
        case 44_100: return 4
        case 32_000: return 5
        case 24_000: return 6
        case 22_050: return 7
        case 16_000: return 8
        case 12_000: return 9
        case 11_025: return 10
        case 8_000:  return 11
        case 7_350:  return 12
        default:     return nil
        }
    }
}
