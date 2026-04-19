import SwiftUI
import RatbatCore

@main
struct RatbatMacApp: App {
    /// Shared preferences live at the app level so the `WindowGroup` and
    /// `Settings` scene see the same object. Not strictly necessary —
    /// `BroadcastPreferences.shared` is a global — but holding it as a
    /// `@StateObject` keeps SwiftUI in the update loop across both scenes.
    @StateObject private var preferences = BroadcastPreferences.shared

    /// Shared library config for the same reason — the main window picks
    /// or displays the music folder and Settings' Library tab can change
    /// it. Both scenes need to observe the same instance so a change
    /// from either propagates.
    @StateObject private var libraryConfig = LibraryConfig()

    var body: some Scene {
        WindowGroup {
            RootView(config: libraryConfig)
                .frame(minWidth: 800, minHeight: 600)
        }

        // macOS's Settings scene is automatically bound to ⌘, and renders
        // in its own window. The PreferencesView mutates the same shared
        // stores that RootView observes, so changes made here flow back
        // into the main window without extra plumbing.
        Settings {
            PreferencesView(preferences: preferences, libraryConfig: libraryConfig)
        }
    }
}
