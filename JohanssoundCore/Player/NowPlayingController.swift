import Foundation
import MediaPlayer
import Combine

/// Bridges ``AudioPlayer`` state into macOS system integrations:
/// the Control Center "Now Playing" widget and hardware media keys
/// (F7 prev / F8 play-pause / F9 next) via `MPRemoteCommandCenter`.
///
/// Owned by ``RootView`` for the lifetime of the app. Observes the
/// player via Combine `sink`s (weak self to avoid retain cycles) and
/// mirrors state into `MPNowPlayingInfoCenter.default().nowPlayingInfo`.
///
/// `@MainActor` because every player property it reads is main-actor
/// isolated. Remote-command closures fire on arbitrary threads, so
/// they hop back via `Task { @MainActor in ... }` before touching the
/// player.
///
/// On iOS, `MPNowPlayingInfoCenter` additionally requires an
/// `AVAudioSession` to be configured. This controller is only
/// instantiated on macOS (from ``RootView``, which is `#if os(macOS)`),
/// so we don't set up a session here. The `MediaPlayer` framework
/// itself imports cleanly on both platforms, which is what the shared
/// Core framework needs.
@MainActor
public final class NowPlayingController {
    private let player: AudioPlayer
    private var cancellables = Set<AnyCancellable>()

    public init(player: AudioPlayer) {
        self.player = player
        setupRemoteCommands()
        observePlayer()
    }

    deinit {
        // Clear the Now Playing widget when this controller goes away.
        // `MPNowPlayingInfoCenter` is documented thread-safe, so reaching
        // it from a nonisolated deinit is fine.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.player.resume() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.player.pause() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.player.togglePlayPause() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.player.next() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.player.previous() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let ev = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            let target = ev.positionTime
            Task { @MainActor in self.player.seek(to: target) }
            return .success
        }
    }

    // MARK: - Observation

    private func observePlayer() {
        // Full info dict on track change.
        player.$currentTrack
            .sink { [weak self] track in
                self?.publishTrack(track)
            }
            .store(in: &cancellables)

        // Playback rate + elapsed time on play/pause toggle.
        player.$isPlaying
            .sink { [weak self] isPlaying in
                self?.updatePlaybackRate(isPlaying: isPlaying)
            }
            .store(in: &cancellables)

        // Elapsed time ticks (AudioPlayer emits ~2x/s).
        player.$progress
            .sink { [weak self] progress in
                self?.updateElapsedTime(progress)
            }
            .store(in: &cancellables)
    }

    // MARK: - Info center updates

    private func publishTrack(_ track: Track?) {
        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updatePlaybackRate(isPlaying: Bool) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.progress
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateElapsedTime(_ seconds: TimeInterval) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
