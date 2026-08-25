import Foundation

/// A small circular byte buffer of encoded AAC bytes with per-client
/// cursors and async reads that suspend until more data arrives.
///
/// Semantics intentionally kept minimal for the spike:
/// - Writes append to a monotonic "total bytes written" counter and
///   overwrite the oldest region when capacity is exceeded.
/// - New clients get a cursor at the current write head (late-join =
///   live tail; they don't have to "catch up" through stale data).
/// - `read(from:)` returns as soon as there's any new data past the
///   cursor. If the writer has lapped the cursor while the reader was
///   slow, the cursor is bumped forward to the oldest still-valid byte
///   and the caller gets whatever's fresh — better than deadlocking a
///   listener.
///
/// Thread-safe via a single `NSLock`. Multiple suspended readers are
/// tracked in a waiter list and all woken on the next write — the
/// broadcaster will usually have 1–few listeners so a broad wake-up is
/// fine.
///
/// `@unchecked Sendable` because we mediate all mutable state through a
/// lock; the compiler can't infer that. This is the canonical pattern
/// for "lock-protected value type" classes under Swift 6.
final class AACRingBuffer: @unchecked Sendable {
    struct Cursor: Sendable {
        /// Monotonic byte index into the infinite stream of "every byte
        /// ever written". We compare against the writer's equivalent
        /// counter to find how far behind this cursor is.
        fileprivate var position: UInt64
    }

    private let capacity: Int
    private var storage: [UInt8]
    /// Total bytes ever written, monotonic. The physical index in
    /// `storage` for a given stream position is `position % capacity`.
    private var totalWritten: UInt64 = 0
    private let lock = NSLock()

    /// Continuations from `read(from:)` callers currently suspended
    /// waiting for more data. Kept in an array; we wake all of them on
    /// every write (the cost is small with a handful of listeners and
    /// the reader decides what to do on wake-up).
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Discontinuity floor: stream positions below this are declared
    /// stale, and readers behind it jump forward to it. Set by
    /// ``markDiscontinuity()`` on a deliberate skip so listeners don't
    /// sit through ~8s of buffered audio from a track the user just
    /// rejected. Natural track ends never touch it — gapless radio
    /// stays gapless; only rejection cuts the backlog.
    private var liveEdgeFloor: UInt64 = 0

    /// Bytes needed to hold `seconds` of audio encoded at `bitrate` bps.
    ///
    /// Sizing in *seconds* rather than bytes is the whole point: a fixed
    /// byte count silently means different amounts of audio at different
    /// quality presets, and the preset in use is the one it was wrong for.
    static func capacity(bitrate: Int, seconds: Double) -> Int {
        max(Int(Double(bitrate) / 8 * seconds), 1024)
    }

    /// Ring sized to hold `seconds` of audio at `bitrate`.
    convenience init(bitrate: Int, seconds: Double) {
        self.init(capacity: Self.capacity(bitrate: bitrate, seconds: seconds))
    }

    /// - Parameter capacity: bytes. Prefer ``init(bitrate:seconds:)`` —
    ///   this overload exists for tests that want an exact, tiny ring.
    init(capacity: Int = 128 * 1024) {
        // This default used to be the only way to build a ring, described
        // as "~128KB, at 128 kbps roughly 8s of AAC". Both halves were a
        // trap: the station broadcasts at `max` (256 kbps), where the same
        // 128KB is 4.1s — and the encode loop deliberately runs
        // `broadcastLeadSeconds` (5s) ahead of the playout head. So the
        // encoder's own runway did not fit in the buffer holding it, and
        // every listener was lapped at steady state rather than only after
        // a stalled read.
        //
        // Callers now size in seconds against the real bitrate. The
        // one-track-ahead prefetch does hide the per-track resolve gaps,
        // so this ring is not covering a track boundary — but it must
        // still hold the encoder's full lead, plus margin for a reader
        // whose socket stalls (a slow Drive block fetch). It does not add
        // to listener desync: the lead is what sets that, and the ring
        // merely has to be big enough to contain it.
        self.capacity = max(capacity, 1024)
        self.storage = [UInt8](repeating: 0, count: self.capacity)
    }

    /// Append encoded AAC bytes. Wakes any suspended readers.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let toWake: [CheckedContinuation<Void, Never>]
        lock.lock()

        let bytesCount = data.count
        if bytesCount >= capacity {
            // New data alone is bigger than the whole buffer. Keep only
            // the trailing `capacity` bytes and jump the counter.
            data.suffix(capacity).withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                storage.withUnsafeMutableBufferPointer { dst in
                    guard let dstBase = dst.baseAddress else { return }
                    dstBase.update(
                        from: src.assumingMemoryBound(to: UInt8.self),
                        count: capacity
                    )
                }
            }
            totalWritten += UInt64(bytesCount)
        } else {
            let writeStart = Int(totalWritten % UInt64(capacity))
            let firstChunk = min(capacity - writeStart, bytesCount)

            data.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                let srcBytes = src.assumingMemoryBound(to: UInt8.self)
                storage.withUnsafeMutableBufferPointer { dst in
                    guard let dstBase = dst.baseAddress else { return }
                    dstBase.advanced(by: writeStart)
                        .update(from: srcBytes, count: firstChunk)
                    if firstChunk < bytesCount {
                        dstBase.update(
                            from: srcBytes.advanced(by: firstChunk),
                            count: bytesCount - firstChunk
                        )
                    }
                }
            }
            totalWritten += UInt64(bytesCount)
        }

        toWake = waiters
        waiters.removeAll()
        lock.unlock()

        for cont in toWake {
            cont.resume()
        }
    }

    /// Declare everything written so far stale: readers behind this point
    /// jump straight to the live edge on their next read. Called on a
    /// deliberate skip, at the old track's final frame boundary (the
    /// encode loop writes whole encoder chunks, so the floor never lands
    /// mid-frame — and ADTS resyncs on its sync word regardless).
    func markDiscontinuity() {
        lock.lock()
        liveEdgeFloor = totalWritten
        lock.unlock()
    }

    /// Cursor for a brand-new listener. Starts at "now" so they don't
    /// have to chew through a stale buffer to catch up.
    /// Has this station ever produced a byte?
    ///
    /// A new listener's cursor starts at the live edge, so on a cold start
    /// there is nothing to read and nothing to wait for except the first
    /// write. Callers use this to avoid promising a stream they cannot yet
    /// fill.
    func hasProducedAudio() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return totalWritten > 0
    }

    func readCursor() -> Cursor {
        lock.lock()
        defer { lock.unlock() }
        return Cursor(position: totalWritten)
    }

    /// Async read: suspend until `totalWritten > cursor.position`, then
    /// return whatever bytes are new. Advances `cursor` in place so the
    /// caller can loop. Returns an empty `Data` if woken without new
    /// data (shouldn't normally happen, but the caller's cancellation
    /// loop will notice).
    func read(from cursor: inout Cursor) async -> Data {
        // Advance past a discontinuity BEFORE anything else. The slow
        // path decides whether to suspend by comparing `totalWritten`
        // against the cursor; leaving a pre-floor position there makes
        // that check say "data available" while `tryRead` correctly
        // finds nothing past the floor — so `read` returns empty
        // immediately and the serve loop busy-spins until the next
        // write. Clamping here keeps the two views consistent.
        cursor.position = clampedToFloor(cursor.position)

        // Fast path: something's already available.
        if let (data, newPos) = tryRead(from: cursor.position) {
            cursor.position = newPos
            return data
        }

        // Slow path: suspend until the next write. We re-check under
        // the lock to avoid a lost-wakeup race between the fast-path
        // check and enqueueing ourselves.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if totalWritten > cursor.position {
                lock.unlock()
                cont.resume()
                return
            }
            waiters.append(cont)
            lock.unlock()
        }

        if let (data, newPos) = tryRead(from: cursor.position) {
            cursor.position = newPos
            return data
        }
        return Data()
    }

    /// Clamp a stream position forward past any discontinuity floor.
    /// Synchronous by necessity: `NSLock` can't be taken from an async
    /// context under Swift 6, so every lock use in this type lives in a
    /// sync helper like this one.
    private func clampedToFloor(_ position: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return max(position, liveEdgeFloor)
    }

    /// Returns `(data, newPosition)` if there's data past `position`,
    /// else `nil`. Bumps the effective start forward if the writer has
    /// lapped the reader.
    private func tryRead(from position: UInt64) -> (Data, UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard totalWritten > position else { return nil }

        let writable = UInt64(capacity)
        let oldestValid = totalWritten > writable ? totalWritten - writable : 0
        // The discontinuity floor outranks the reader's own position:
        // audio before it belongs to a skipped track nobody wants.
        let effective = max(position, oldestValid, liveEdgeFloor)
        let available = Int(totalWritten - effective)
        if available == 0 { return nil }

        let startIdx = Int(effective % UInt64(capacity))
        var data = Data(count: available)
        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            storage.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress else { return }
                let firstChunk = min(capacity - startIdx, available)
                dst.update(from: srcBase.advanced(by: startIdx), count: firstChunk)
                if firstChunk < available {
                    dst.advanced(by: firstChunk)
                        .update(from: srcBase, count: available - firstChunk)
                }
            }
        }
        return (data, effective + UInt64(available))
    }
}
