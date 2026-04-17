import Foundation
import AVFoundation

/// Reads PCM buffers from a single ``Track`` file on demand, converting to
/// a fixed output format (Float32 stereo, 44.1 kHz) so downstream encoders
/// don't have to care what the source file's sample rate or channel count
/// is.
///
/// Spike-grade (Task 3.2): deliberately small API — open, read, close —
/// with no seeking, looping or timing. The broadcaster drives it round-
/// robin over a queue. If this falls over (e.g. a file format AVAudioFile
/// can't open) we'll learn that here and pick a different decoder path.
///
/// Implemented as a plain class (not an actor) because the broadcaster's
/// encode loop owns it exclusively on a single detached task, and moving
/// `AVAudioPCMBuffer` across actor boundaries trips Swift 6 Sendable
/// diagnostics (the buffer is a reference type without a Sendable
/// conformance). `@unchecked Sendable` lets us hand a fresh instance
/// into the detached task once; after that it's used serially.
final class AudioDecoder: @unchecked Sendable {
    /// Our pipeline's canonical format: what the encoder expects on input.
    /// Chosen to match AAC's native rate (44.1 kHz) so AudioConverter
    /// doesn't have to resample internally, and Float32 stereo because
    /// AVAudioFile reads into Float32 non-interleaved by default when you
    /// build an `AVAudioFormat(standardFormatWithSampleRate:...)`.
    static let outputFormat: AVAudioFormat = {
        // Force-unwrap: the arguments are hard-coded, the standard format
        // constructor will not fail for them. If it ever does, we'd rather
        // crash loudly in a spike than swallow it.
        AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        )!
    }()

    /// Frames we pull from AVAudioFile per read. Small enough to keep
    /// latency low, large enough that we aren't thrashing the file cursor.
    private static let framesPerRead: AVAudioFrameCount = 4096

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    /// Cached input format so we can lazily build the converter only when
    /// the source format differs from ``outputFormat``.
    private var sourceFormat: AVAudioFormat?

    init() {}

    /// Open ``track`` for reading. Replaces any previously-open file.
    /// Throws if AVAudioFile can't read the URL (format unsupported,
    /// file missing, permissions, etc.). Caller decides whether to skip
    /// and move on or surface the error.
    func open(_ track: Track) throws {
        try open(url: track.url)
    }

    /// Open an arbitrary file URL for reading. Same semantics as
    /// ``open(_:)`` but without needing a full ``Track`` — the
    /// ``TrackSource`` pipeline calls this with a ``TrackSourceItem``
    /// URL since NTS-derived items don't carry a matching library
    /// ``Track`` value.
    func open(url: URL) throws {
        let audioFile = try AVAudioFile(forReading: url)
        self.file = audioFile
        self.sourceFormat = audioFile.processingFormat
        // Build a converter only if the source differs from our canonical
        // output. Otherwise a straight copy is fine and faster.
        if audioFile.processingFormat != Self.outputFormat {
            self.converter = AVAudioConverter(
                from: audioFile.processingFormat,
                to: Self.outputFormat
            )
        } else {
            self.converter = nil
        }
    }

    /// Pull the next chunk of PCM, already in ``outputFormat``. Returns
    /// `nil` at EOF, on error, or if nothing is open. The broadcaster
    /// interprets `nil` as "advance to next track".
    func readNextBuffer() -> AVAudioPCMBuffer? {
        guard let file = file, let sourceFormat = sourceFormat else { return nil }

        // Allocate a source-format buffer and read into it first, then
        // (if needed) convert to the canonical output format.
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: Self.framesPerRead
        ) else { return nil }

        do {
            try file.read(into: inputBuffer)
        } catch {
            return nil
        }

        if inputBuffer.frameLength == 0 {
            return nil  // EOF
        }

        // Fast path: source already matches the pipeline format.
        guard let converter = converter else {
            return inputBuffer
        }

        // Slow path: resample / rechannel. Capacity scaling covers the
        // rate change; for downmix/upmix without rate change it's a
        // no-op-on-capacity.
        let ratio = Self.outputFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            Double(inputBuffer.frameLength) * ratio + 1024
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: outputCapacity
        ) else { return nil }

        // Wrap the "already consumed" flag in a reference box so the
        // @Sendable converter callback can mutate it without tripping
        // Swift 6's capture diagnostics. AudioDecoder is serial anyway
        // (the broadcaster owns it exclusively), so unsafe mutation here
        // is fine — we just need to get past the compiler's sendability
        // check on the closure.
        let consumedBox = MutableBox(false)
        nonisolated(unsafe) let capturedBuffer = inputBuffer
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if consumedBox.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumedBox.value = true
            inputStatus.pointee = .haveData
            return capturedBuffer
        }

        switch status {
        case .haveData, .inputRanDry:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .endOfStream, .error:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Release the current file. Safe to call more than once.
    func close() {
        file = nil
        converter = nil
        sourceFormat = nil
    }
}

/// Tiny reference box used to mutate a bool from inside a `@Sendable`
/// closure without triggering Swift 6's "capture of var in Sendable
/// context" diagnostic. We use it in exactly one place (the
/// `AudioConverter` fill callback) where the converter is guaranteed to
/// invoke the closure serially from within its own call, so the usual
/// thread-safety concerns don't apply.
final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
