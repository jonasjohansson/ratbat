import Foundation
import AVFoundation
import Combine
import SwiftUI
import OSLog

/// Plays audio tracks from a queue and publishes playback state for the UI.
///
/// v1 wraps `AVPlayer` (not `AVQueuePlayer`) with a manually-tracked index
/// into a `[Track]` queue. `AVQueuePlayer` has awkward behaviour around
/// replacing items mid-play that makes it hard to keep an observable
/// `currentTrack` in sync; manual index tracking sidesteps that entirely.
///
/// `@MainActor` so every published mutation happens on the main actor and
/// SwiftUI views can bind directly to the published properties without
/// additional actor hops. The progress observer and notification handler
/// hop onto the main actor explicitly via a `Task`, which is what Swift 6
/// strict concurrency requires (their closures are `@Sendable`).
@MainActor
public final class AudioPlayer: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var isPlaying: Bool = false
    /// Current playback time in seconds. Updated ~2x per second while playing.
    @Published public private(set) var progress: TimeInterval = 0
    @Published public private(set) var queue: [Track] = []
    /// Last playback error, surfaced as a string so the UI can render it
    /// without knowing about `NSError`. Cleared on a successful load or on
    /// the next user-initiated play. Used by ``PlayerView`` to render a
    /// banner when AVPlayer can't open a file — replaces the silent-fail
    /// behaviour that used to leave the UI stuck at "No track" with no hint
    /// why.
    @Published public private(set) var error: String?

    // MARK: - Internals

    private let player: AVPlayer
    private let logger = Logger(
        subsystem: RatbatLog.subsystem,
        category: "player"
    )

    /// Index into `queue` of the currently-loaded track, or `nil` if idle.
    private var currentIndex: Int?

    /// KVO token for the currently-loaded `AVPlayerItem.status`. Replaced
    /// on every `loadTrack` so each item gets its own observer; dropped
    /// when the player goes idle.
    private var itemStatusObserver: NSKeyValueObservation?

    /// Token returned by `addPeriodicTimeObserver`. We mark it
    /// `nonisolated(unsafe)` so `deinit` (which is nonisolated) can read it
    /// to remove the observer; it's written exactly once during `init` and
    /// otherwise never touched.
    private nonisolated(unsafe) var progressObserver: Any?

    /// Token returned by `NotificationCenter.addObserver(forName:...)`. Same
    /// rationale as `progressObserver`.
    private nonisolated(unsafe) var endObserver: NSObjectProtocol?

    public init() {
        self.player = AVPlayer()
        observeProgress()
        observeTrackEnd()
    }

    deinit {
        // Safe from a nonisolated deinit: `AVPlayer.removeTimeObserver` and
        // `NotificationCenter.removeObserver` are thread-safe, and the tokens
        // are `nonisolated(unsafe)` so we can read them here.
        if let token = progressObserver {
            player.removeTimeObserver(token)
        }
        if let token = endObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Queue management

    /// Replace the queue and start playing `queue[index]`.
    ///
    /// If `queue` is empty or `index` is out of range, this is a no-op.
    public func play(queue: [Track], startingAt index: Int = 0) {
        guard !queue.isEmpty, queue.indices.contains(index) else { return }
        self.queue = queue
        loadTrack(at: index)
        player.play()
        isPlaying = true
    }

    /// Replace the queue with a single track and start playing it.
    public func play(_ track: Track) {
        play(queue: [track], startingAt: 0)
    }

    // MARK: - Transport

    public func pause() {
        player.pause()
        isPlaying = false
    }

    /// Resume playback. If nothing is loaded but the queue is non-empty,
    /// start from the first track.
    public func resume() {
        if currentTrack == nil, !queue.isEmpty {
            loadTrack(at: 0)
        }
        player.play()
        isPlaying = true
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    /// Advance to the next track. If already at the last track, stop.
    public func next() {
        guard let index = currentIndex else { return }
        let nextIndex = index + 1
        if queue.indices.contains(nextIndex) {
            loadTrack(at: nextIndex)
            player.play()
            isPlaying = true
        } else {
            // End of queue: stop playback but keep the last track visible
            // so the UI can show "finished" state instead of going blank.
            player.pause()
            isPlaying = false
        }
    }

    /// Step back one track. No-op at index 0.
    public func previous() {
        guard let index = currentIndex, index > 0 else { return }
        loadTrack(at: index - 1)
        player.play()
        isPlaying = true
    }

    /// Seek to `seconds` within the current item.
    public func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target)
        progress = seconds
    }

    // MARK: - Private helpers

    private func loadTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        let url = track.url

        // Pre-flight filesystem checks. When macOS TCC silently blocks a
        // path (e.g. the music folder lives in `~/Library/CloudStorage/`
        // and the app's code hash changed since the user last granted
        // access), `AVPlayer` returns the opaque `-11800 AVErrorUnknown`
        // and the UI sits at "No track" forever. Checking existence +
        // readability up front lets us surface a specific, actionable
        // message so the user knows where to look.
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let msg = "File not found on disk. Cloud file not materialized, or Ratbat lacks permission to see this folder (Privacy & Security → Full Disk Access). Path: \(url.path)"
            self.error = msg
            self.logger.error("loadTrack: not found — \(url.path, privacy: .public)")
            return
        }
        if !fm.isReadableFile(atPath: url.path) {
            let msg = "File exists but isn't readable. Check Privacy & Security → Full Disk Access for Ratbat. Path: \(url.path)"
            self.error = msg
            self.logger.error("loadTrack: unreadable — \(url.path, privacy: .public)")
            return
        }

        let item = AVPlayerItem(url: url)

        // Observe `status` so AVPlayer failures surface as a visible
        // error instead of a silent stall. Replace any prior observer —
        // each `AVPlayerItem` has its own token and we only care about
        // the currently-loaded one.
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.error = nil
                case .failed:
                    let desc = item.error?.localizedDescription
                        ?? String(describing: item.error)
                    self.error = "AVPlayer couldn't load: \(desc)"
                    self.logger.error(
                        "AVPlayerItem failed for \(url.path, privacy: .public): \(desc, privacy: .public)"
                    )
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        player.replaceCurrentItem(with: item)
        currentIndex = index
        currentTrack = track
        progress = 0
        error = nil
        logger.info("loadTrack: \(url.path, privacy: .public)")
    }

    private func observeProgress() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        // Closure is `@Sendable` under Swift 6. We requested `.main` queue so
        // it fires on the main thread, but the compiler still needs an actor
        // hop to touch `@MainActor` state — hence the `Task { @MainActor }`.
        progressObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                self?.progress = seconds
            }
        }
    }

    private func observeTrackEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.next()
            }
        }
    }
}
