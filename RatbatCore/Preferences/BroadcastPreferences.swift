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

    /// Target share of plays that should be music the owner does not already
    /// own, in [0, 1]. See ``SelectionPolicy`` for the exact meaning — it is a
    /// deterministic ratio over plays, not a per-track probability.
    ///
    /// Stored as a Double because `@AppStorage` cannot hold an Optional.
    /// ANY NEGATIVE VALUE MEANS "unset" — the dial is off and the upstream
    /// ranking is left alone. That sentinel is why the shipped default is
    /// -1 and not 0.0: a 0.0 dial is an active reorder (it leads with owned
    /// music), so shipping 0.0 would change what an existing listener hears.
    @AppStorage("ratbat.selection.newMusicShare")
    private var newMusicShareRaw: Double = BroadcastPreferences.newMusicShareUnset

    /// Sentinel for "the owner has never set the dial".
    static let newMusicShareUnset: Double = -1

    /// Whether to drop candidates that ``MixSetRule`` classifies as mix sets.
    /// Ships off: it removes music, and the shadow records written while it is
    /// off are what let the owner see what it *would* remove before enabling it.
    @AppStorage("ratbat.selection.excludeMixSets")
    private var excludeMixSetsRaw: Bool = false

    /// Slugs of stations to broadcast automatically at launch. Slugs, not
    /// ``Station/ID``s: stations persist next to the library and sync
    /// across machines via the shared drive, while preferences are
    /// per-machine `UserDefaults` — the slug is the identifier stable
    /// across both stores (and readable in `defaults read`). Stored
    /// comma-joined; slugs are URL-safe so the separator can't collide.
    /// A slug with no matching station is skipped silently at launch —
    /// the station may live in another machine's library, or the station
    /// was renamed (slugs derive from names, so a rename orphans the
    /// entry; per-machine prefs make cross-machine migration impossible,
    /// so silent-skip is the designed behavior, not an oversight).
    @AppStorage("ratbat.broadcast.autoStartSlugs")
    private var autoStartSlugsRaw: String = ""

    /// Shared secret that separates the owner from guest listeners on the
    /// public HTTP surface. Requests to /like, /skip, /next must carry it;
    /// without it the radio is listen-only — guests get a radio, not a
    /// mixer. Generated on first read (empty = never generated). Shown in
    /// Settings → Broadcast for copying into the web player once per
    /// device. UserDefaults, not Keychain — same threat model note as the
    /// Last.fm key above.
    @AppStorage("ratbat.broadcast.ownerToken")
    private var ownerTokenRaw: String = ""

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

    /// The two listener preferences as one value, for handing across the
    /// actor boundary into the selection pipeline.
    ///
    /// Does NOT tick ``revision``: both settings take effect at the next pool
    /// refill, so changing them must not raise the "needs restart" nag the way
    /// quality/port do. A station picks the change up on its own.
    public var selectionPolicy: SelectionPolicy {
        get {
            SelectionPolicy(
                newMusicShare: newMusicShareRaw < 0 ? nil : newMusicShareRaw,
                excludeMixSets: excludeMixSetsRaw,
                mixSetMinimumDuration: MixSetRule.defaultMinimumDuration
            )
        }
        set {
            // Read back through the clamping initialiser rather than storing
            // the caller's value directly.
            let clamped = SelectionPolicy(
                newMusicShare: newValue.newMusicShare,
                excludeMixSets: newValue.excludeMixSets,
                mixSetMinimumDuration: newValue.mixSetMinimumDuration
            )
            newMusicShareRaw = clamped.newMusicShare ?? BroadcastPreferences.newMusicShareUnset
            excludeMixSetsRaw = clamped.excludeMixSets
        }
    }

    /// Ordered list of auto-start slugs. Note: does NOT tick ``revision``
    /// — toggling auto-start has no effect on a running pipeline, so it
    /// must not raise the "needs restart" nag the way quality/port do.
    public var autoStartSlugs: [String] {
        get { autoStartSlugsRaw.split(separator: ",").map(String.init) }
        set { autoStartSlugsRaw = newValue.joined(separator: ",") }
    }

    public func isAutoStart(slug: String) -> Bool {
        autoStartSlugs.contains(slug)
    }

    /// The owner token, generating one on first access. Does not tick
    /// ``revision`` — the token never affects a running pipeline.
    ///
    /// Settable so the owner can choose a memorable passcode in
    /// Settings → Broadcast instead of ferrying a UUID between devices.
    /// Assigning blank means "issue me a fresh random one", not "no key":
    /// an empty token would make ``isOwner(token:)`` reject everything,
    /// which reads as "the buttons broke", not as a security posture.
    public var ownerToken: String {
        get {
            if ownerTokenRaw.isEmpty {
                ownerTokenRaw = UUID().uuidString.lowercased()
            }
            return ownerTokenRaw
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            ownerTokenRaw = trimmed.isEmpty ? UUID().uuidString.lowercased() : trimmed
        }
    }

    /// Whitespace- and case-insensitive comparison against the stored key.
    ///
    /// Both tolerances are there because the key is now typed by a human
    /// rather than pasted from a URL: a phone keyboard capitalises the
    /// first letter unprompted, and a passcode copied out of a note tends
    /// to carry a trailing newline. Either one produces "it says wrong and
    /// I can't see why", which is the exact failure this is meant to avoid.
    /// Folding case costs a few bits against an attacker who is already
    /// throttled (see `RadioBroadcaster.ownerGate`) and who would be
    /// guessing a shared passcode over a home tunnel; the trade is
    /// deliberate. Constant-time comparison is overkill for the same reason.
    public func isOwner(token: String?) -> Bool {
        guard let token else { return false }
        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        return candidate.compare(ownerToken, options: .caseInsensitive) == .orderedSame
    }

    /// Add or remove `slug` from the auto-start list. Idempotent in both
    /// directions so a double-toggle can't duplicate an entry.
    public func setAutoStart(_ enabled: Bool, slug: String) {
        var slugs = autoStartSlugs
        if enabled {
            guard !slugs.contains(slug) else { return }
            slugs.append(slug)
        } else {
            slugs.removeAll { $0 == slug }
        }
        autoStartSlugs = slugs
    }

    /// Slugs of the stations that were live at last observation — the
    /// broadcaster maintains this on every start/stop so a restart can
    /// resume where it was. Deliberate stops forget the slug; stopAll
    /// (the shutdown/restart-all path) and crashes leave it intact.
    /// Same storage rationale as ``autoStartSlugs``; no revision tick.
    @AppStorage("ratbat.broadcast.lastLiveSlugs")
    private var lastLiveSlugsRaw: String = ""

    public var lastLiveSlugs: [String] {
        get { lastLiveSlugsRaw.split(separator: ",").map(String.init) }
        set { lastLiveSlugsRaw = newValue.joined(separator: ",") }
    }

    public func rememberLive(slug: String) {
        var slugs = lastLiveSlugs
        guard !slugs.contains(slug) else { return }
        slugs.append(slug)
        lastLiveSlugs = slugs
    }

    public func forgetLive(slug: String) {
        lastLiveSlugs = lastLiveSlugs.filter { $0 != slug }
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
        defaults.removeObject(forKey: "ratbat.broadcast.autoStartSlugs")
        defaults.removeObject(forKey: "ratbat.broadcast.ownerToken")
        defaults.removeObject(forKey: "ratbat.broadcast.lastLiveSlugs")
        defaults.removeObject(forKey: "ratbat.selection.newMusicShare")
        defaults.removeObject(forKey: "ratbat.selection.excludeMixSets")
        // Removing the key is enough for the String-backed settings above, but
        // not for these two: this instance's `@AppStorage` wrappers keep
        // serving the last value they wrote, so a removal alone leaves
        // `selectionPolicy` reading back whatever the previous caller set.
        // Assign the defaults through the wrappers so the reset is observable
        // on `self`, which is what callers (and the tests) actually check.
        newMusicShareRaw = SelectionPolicy.default.newMusicShare ?? BroadcastPreferences.newMusicShareUnset
        excludeMixSetsRaw = SelectionPolicy.default.excludeMixSets
        revision &+= 1
    }
}
