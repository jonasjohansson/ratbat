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

    init(capacity: Int = 256 * 1024) {
        // Default ~256KB. At 128 kbps that's roughly 16s of AAC — plenty
        // for a handful of clients that might be a few seconds behind.
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

    /// Cursor for a brand-new listener. Starts at "now" so they don't
    /// have to chew through a stale buffer to catch up.
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

    /// Returns `(data, newPosition)` if there's data past `position`,
    /// else `nil`. Bumps the effective start forward if the writer has
    /// lapped the reader.
    private func tryRead(from position: UInt64) -> (Data, UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard totalWritten > position else { return nil }

        let writable = UInt64(capacity)
        let oldestValid = totalWritten > writable ? totalWritten - writable : 0
        let effective = max(position, oldestValid)
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
