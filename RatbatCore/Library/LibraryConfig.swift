import Foundation
import Combine

/// Persists the user's chosen music folder URL across launches and
/// publishes changes so views can react when the folder is re-picked from
/// Settings.
///
/// v1 stores the folder as a plain file path in `UserDefaults`. This works
/// because the macOS app ships unsandboxed — the app has ambient filesystem
/// access, so a reconstructed `URL(fileURLWithPath:)` is enough.
///
/// If/when sandboxing is enabled, switch to security-scoped bookmarks
/// (`url.bookmarkData(options: .withSecurityScope, ...)`). Those require a
/// real user-approved `NSOpenPanel` URL, so they cannot be unit-tested with
/// fabricated paths — which is why v1 stays path-based.
///
/// ``reloadNonce`` ticks on ``requestReload()`` so a view observing
/// ``musicFolder`` + nonce together can also honour "re-scan current
/// folder" without the folder URL actually changing.
public final class LibraryConfig: ObservableObject {
    private let defaults: UserDefaults
    private let key = "ratbat.musicFolder"

    @Published public var musicFolder: URL? {
        didSet {
            guard !isLoading else { return }
            if let url = musicFolder {
                defaults.set(url.path, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Bumps every time a caller asks for a re-scan of the current folder.
    /// Composite task ids can observe this alongside ``musicFolder`` to
    /// re-fire on reload even when the path itself hasn't changed.
    @Published public private(set) var reloadNonce: Int = 0

    /// Guards the initial `@Published` assignment in `init` from writing
    /// the value we just read straight back to `UserDefaults`.
    private var isLoading = true

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: key) {
            self.musicFolder = URL(fileURLWithPath: path)
        }
        self.isLoading = false
    }

    /// Ask observers to re-scan the current folder. Useful when files
    /// appeared/disappeared on disk and the user wants a fresh index
    /// without changing folders.
    public func requestReload() {
        reloadNonce &+= 1
    }
}
