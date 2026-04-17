import Foundation
import AVFoundation
import AudioToolbox

/// Encodes PCM buffers (44.1 kHz Float32 stereo) to AAC-LC frames with
/// ADTS headers so the resulting bytes are a legal `audio/aac` stream
/// that VLC / ffplay / most browsers can consume directly.
///
/// Spike implementation (Task 3.2): uses `AVAudioConverter` instead of
/// the raw `AudioConverter` C API. We tried the C API first and hit the
/// usual callback-lifetime + Swift 6 `@Sendable` friction; `AVAudioConverter`
/// wraps the same machinery and plays well with strict concurrency.
///
/// Output frame size is fixed by AAC-LC at 1024 PCM samples per frame,
/// so each `encode(_:)` call drains the incoming PCM into as many 1024-
/// sample AAC frames as possible and returns the concatenated ADTS
/// stream. Residual input samples (< 1024) are buffered until the next
/// call.
///
/// Not thread-safe on its own — the broadcaster owns exactly one
/// instance and calls it serially from its encode task, so we dodge the
/// locking question for the spike.
final class AACEncoder: @unchecked Sendable {
    /// Payload frames per AAC-LC packet, per the spec. This is what
    /// AudioConverter will emit regardless of how big an input buffer
    /// we push in — it packetises internally.
    private static let aacFrameSamples: AVAudioFrameCount = 1024

    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let destFormat: AVAudioFormat
    private let sampleFreqIdx: UInt8
    private let channelConfig: UInt8

    /// Pending PCM that hasn't filled a 1024-sample AAC frame yet. We
    /// append each incoming buffer here and drain frame-by-frame.
    private var pending: AVAudioPCMBuffer?

    /// Initialize the encoder. ``inputFormat`` should match
    /// ``AudioDecoder.outputFormat`` (44.1 kHz Float32 stereo).
    init(
        inputFormat: AVAudioFormat,
        sampleRate: Double = 44_100,
        channels: Int = 2,
        bitrate: Int = 128_000
    ) throws {
        guard let freqIdx = ADTSHeader.sampleFrequencyIndex(for: sampleRate) else {
            throw EncoderError.unsupportedSampleRate(sampleRate)
        }

        var destASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.aacFrameSamples),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let destFormat = AVAudioFormat(streamDescription: &destASBD) else {
            throw EncoderError.formatCreationFailed
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: destFormat) else {
            throw EncoderError.converterCreationFailed
        }
        conv.bitRate = bitrate

        self.converter = conv
        self.sourceFormat = inputFormat
        self.destFormat = destFormat
        self.sampleFreqIdx = freqIdx
        self.channelConfig = UInt8(channels)
    }

    /// Feed a PCM chunk. Returns concatenated ADTS-wrapped AAC bytes, or
    /// `nil` if we didn't have a full frame's worth of input yet.
    func encode(_ pcm: AVAudioPCMBuffer) throws -> Data? {
        guard pcm.format == sourceFormat else {
            throw EncoderError.formatMismatch
        }

        appendToPending(pcm)

        var out = Data()
        while let buf = nextFrameFromPending() {
            if let frame = try encodeOneFrame(buf) {
                out.append(frame)
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Pending-buffer plumbing

    private func appendToPending(_ pcm: AVAudioPCMBuffer) {
        if let existing = pending {
            // Grow a new buffer big enough to hold old + new, and splice.
            let totalFrames = existing.frameLength + pcm.frameLength
            guard let merged = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: totalFrames
            ) else { return }
            copyFrames(
                from: existing,
                sourceOffset: 0,
                to: merged,
                destOffset: 0,
                frameCount: existing.frameLength
            )
            copyFrames(
                from: pcm,
                sourceOffset: 0,
                to: merged,
                destOffset: existing.frameLength,
                frameCount: pcm.frameLength
            )
            merged.frameLength = totalFrames
            pending = merged
        } else {
            // Copy into a fresh buffer so we own it (pcm may be reused
            // by the decoder on the next read).
            guard let copy = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: pcm.frameLength
            ) else { return }
            copyFrames(
                from: pcm,
                sourceOffset: 0,
                to: copy,
                destOffset: 0,
                frameCount: pcm.frameLength
            )
            copy.frameLength = pcm.frameLength
            pending = copy
        }
    }

    private func nextFrameFromPending() -> AVAudioPCMBuffer? {
        guard let buf = pending, buf.frameLength >= Self.aacFrameSamples else {
            return nil
        }
        guard let frame = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: Self.aacFrameSamples
        ) else { return nil }
        copyFrames(
            from: buf,
            sourceOffset: 0,
            to: frame,
            destOffset: 0,
            frameCount: Self.aacFrameSamples
        )
        frame.frameLength = Self.aacFrameSamples

        // Shift leftover frames forward in `pending`.
        let remaining = buf.frameLength - Self.aacFrameSamples
        if remaining == 0 {
            pending = nil
        } else {
            guard let shifted = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: remaining
            ) else {
                pending = nil
                return frame
            }
            copyFrames(
                from: buf,
                sourceOffset: Self.aacFrameSamples,
                to: shifted,
                destOffset: 0,
                frameCount: remaining
            )
            shifted.frameLength = remaining
            pending = shifted
        }
        return frame
    }

    /// Float32 non-interleaved copy across our standard format. We don't
    /// support other layouts in the spike — if the decoder ever gave us
    /// something else, `floatChannelData` would be nil and the copy just
    /// no-ops (which shows up as silence — obvious in manual testing).
    private func copyFrames(
        from source: AVAudioPCMBuffer,
        sourceOffset: AVAudioFrameCount,
        to dest: AVAudioPCMBuffer,
        destOffset: AVAudioFrameCount,
        frameCount: AVAudioFrameCount
    ) {
        guard let src = source.floatChannelData,
              let dst = dest.floatChannelData else { return }
        let channels = Int(source.format.channelCount)
        for ch in 0..<channels {
            let srcPtr = src[ch].advanced(by: Int(sourceOffset))
            let dstPtr = dst[ch].advanced(by: Int(destOffset))
            dstPtr.update(from: srcPtr, count: Int(frameCount))
        }
    }

    // MARK: - Single-frame encode

    /// Encodes exactly 1024 PCM samples into one ADTS-wrapped AAC frame.
    private func encodeOneFrame(_ pcm: AVAudioPCMBuffer) throws -> Data? {
        // A 128kbps AAC-LC frame at 44.1kHz is ~375 bytes; 4096 is roomy.
        guard let compressed = AVAudioCompressedBuffer(
            format: destFormat,
            packetCapacity: 1,
            maximumPacketSize: 4096
        ) as AVAudioCompressedBuffer? else {
            return nil
        }

        // See AudioDecoder for the rationale on MutableBox + nonisolated(unsafe)
        // — same @Sendable closure capture dance.
        let consumedBox = MutableBox(false)
        nonisolated(unsafe) let capturedPCM = pcm
        var convError: NSError?
        let status = converter.convert(to: compressed, error: &convError) { _, inputStatus in
            if consumedBox.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumedBox.value = true
            inputStatus.pointee = .haveData
            return capturedPCM
        }

        if let convError { throw convError }

        switch status {
        case .haveData:
            return extractADTSFrame(from: compressed)
        case .inputRanDry, .endOfStream, .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private func extractADTSFrame(from compressed: AVAudioCompressedBuffer) -> Data? {
        let packetCount = Int(compressed.packetCount)
        guard packetCount > 0 else { return nil }

        // AVAudioCompressedBuffer holds N packets back-to-back in `data`,
        // with per-packet sizes/offsets in `packetDescriptions`.
        guard let descs = compressed.packetDescriptions else { return nil }

        var out = Data()
        let base = compressed.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<packetCount {
            let desc = descs[i]
            let size = Int(desc.mDataByteSize)
            let offset = Int(desc.mStartOffset)
            let header = ADTSHeader(
                profile: 1,                 // AAC LC = AOT 2, ADTS profile = AOT - 1 = 1
                sampleFreqIdx: sampleFreqIdx,
                channelConfig: channelConfig,
                payloadLength: size
            )
            out.append(header.data)
            out.append(UnsafeBufferPointer(start: base.advanced(by: offset), count: size))
        }
        return out
    }

    // MARK: - Errors

    enum EncoderError: Error {
        case unsupportedSampleRate(Double)
        case formatCreationFailed
        case converterCreationFailed
        case formatMismatch
    }
}
