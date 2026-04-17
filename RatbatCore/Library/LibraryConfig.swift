import Foundation

/// Persists the user's chosen music folder URL across launches.
///
/// v1 stores the folder as a plain file path in `UserDefaults`. This works
/// because the macOS app ships unsandboxed — the app has ambient filesystem
/// access, so a reconstructed `URL(fileURLWithPath:)` is enough.
///
/// If/when sandboxing is enabled, switch to security-scoped bookmarks
/// (`url.bookmarkData(options: .withSecurityScope, ...)`). Those require a
/// real user-approved `NSOpenPanel` URL, so they cannot be unit-tested with
/// fabricated paths — which is why v1 stays path-based.
public final class LibraryConfig {
    private let defaults: UserDefaults
    private let key = "ratbat.musicFolder"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var musicFolder: URL? {
        get {
            guard let path = defaults.string(forKey: key) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            if let url = newValue {
                defaults.set(url.path, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
