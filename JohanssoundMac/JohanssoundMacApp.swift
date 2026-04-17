import SwiftUI
import JohanssoundCore

@main
struct JohanssoundMacApp: App {
    /// Shared preferences live at the app level so the `WindowGroup` and
    /// `Settings` scene see the same object. Not strictly necessary —
    /// `BroadcastPreferences.shared` is a global — but holding it as a
    /// `@StateObject` keeps SwiftUI in the update loop across both scenes.
    @StateObject private var preferences = BroadcastPreferences.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 800, minHeight: 600)
        }

        // macOS's Settings scene is automatically bound to ⌘, and renders
        // in its own window. The PreferencesView mutates the same shared
        // store that RootView's broadcaster observes, so changes made here
        // flip `needsRestart` on the broadcaster.
        Settings {
            PreferencesView(preferences: preferences)
        }
    }
}
