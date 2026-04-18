import Foundation
import SwiftUI

/// Audio bitrate presets offered to the user. Ceilings at 256 kbps because
/// that's AAC-LC's practical ceiling; anything higher rarely survives the
/// encoder without artifacts and buys nothing perceptible for the use case.
public enum AudioQuality: String, CaseIterable, Hashable, Codable, Sendable {
    case voice = "voice"         // 64 kbps
    case standard = "standard"   // 128 kbps (default)
    case high = "high"           // 192 kbps
    case max = "max"             // 256 kbps (AAC ceiling)

    public var bitrate: Int {
        switch self {
        case .voice: return 64_000
        case .standard: return 128_000
        case .high: return 192_000
        case .max: return 256_000
        }
    }

    public var label: String {
        switch self {
        case .voice: return "Voice (64 kbps)"
        case .standard: return "Standard (128 kbps)"
        case .high: return "High (192 kbps)"
        case .max: return "Max (256 kbps)"
        }
    }
}

/// Output sample rate. 44.1 kHz is CD-lineage (what the decoder native
/// format targets today); 48 kHz is the video-audio convention and the
/// ceiling for typical music streaming.
public enum SampleRate: Int, CaseIterable, Hashable, Codable, Sendable {
    case hz44100 = 44100
    case hz48000 = 48000

    public var label: String {
        switch self {
        case .hz44100: return "44.1 kHz (CD quality)"
        case .hz48000: return "48 kHz (video audio)"
        }
    }
}

/// Central store for user-facing radio settings, backed by `@AppStorage`.
///
/// Task 3.8: swap the hardcoded `128_000 bps @ 44.1 kHz on port 18000` out
/// for a persisted triple so the UI can expose it via the macOS Settings
/// scene. `@AppStorage` can't be wrapped directly in `@Published` (the
/// wrappers don't compose), so the typed getters/setters mirror the raw
/// storage values — SwiftUI still sees changes because each write flows
/// through the underlying `@AppStorage` which is itself a DynamicProperty
/// and triggers view updates through the `ObservableObject`.
///
/// All mutation runs on the main actor — this type owns the shared
/// singleton Preferences, and preferences are a UI concern.
@MainActor
public final class BroadcastPreferences: ObservableObject {
    @AppStorage("ratbat.broadcast.quality")
    private var qualityRaw: String = AudioQuality.standard.rawValue

    @AppStorage("ratbat.broadcast.sampleRate")
    private var sampleRateRaw: Int = SampleRate.hz44100.rawValue

    @AppStorage("ratbat.broadcast.port")
    public var port: Int = 18000

    @AppStorage("ratbat.broadcast.icyMetadata")
    public var icyMetadataEnabled: Bool = true

    /// Last.fm API key for generative Last.fm-backed stations. Free to
    /// register at https://www.last.fm/api/account/create. Empty string
    /// disables the Last.fm source — ``RadioBroadcaster`` surfaces a
    /// user-visible error if a Last.fm station is started without one.
    /// Stored in `UserDefaults` for simplicity; migrate to Keychain if the
    /// threat model ever grows past "single user, local Mac".
    @AppStorage("ratbat.lastfm.apiKey")
    public var lastFMAPIKey: String = ""

    /// Republishes whenever any stored setting changes so Combine observers
    /// (notably ``RadioBroadcaster``) can mark themselves "needs restart".
    /// `@AppStorage` doesn't expose a publisher we can subscribe to, so we
    /// nudge this manually inside the setters.
    @Published public private(set) var revision: Int = 0

    public var quality: AudioQuality {
        get { AudioQuality(rawValue: qualityRaw) ?? .standard }
        set {
            qualityRaw = newValue.rawValue
            revision &+= 1
        }
    }

    public var sampleRate: SampleRate {
        get { SampleRate(rawValue: sampleRateRaw) ?? .hz44100 }
        set {
            sampleRateRaw = newValue.rawValue
            revision &+= 1
        }
    }

    /// Process-wide shared instance. UI surfaces and the broadcaster read
    /// from the same store so changing a value in one place shows up
    /// everywhere without plumbing.
    public static let shared = BroadcastPreferences()

    public init() {}

    // MARK: - Test support

    /// Wipe every stored preference key to its default. Used by tests that
    /// want a clean slate; production code has no reason to call this.
    public func resetToDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "ratbat.broadcast.quality")
        defaults.removeObject(forKey: "ratbat.broadcast.sampleRate")
        defaults.removeObject(forKey: "ratbat.broadcast.port")
        defaults.removeObject(forKey: "ratbat.broadcast.icyMetadata")
        revision &+= 1
    }
}
