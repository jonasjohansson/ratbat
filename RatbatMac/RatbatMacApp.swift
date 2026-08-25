import SwiftUI
import AppKit
import RatbatCore

/// Runs the broadcaster's teardown when the app is actually quitting.
///
/// Without this, quitting Ratbat left its `cloudflared` child running:
/// reparented to launchd, still holding a tunnel connection, still proxying
/// to the broadcast port. The next launch spawned another, so restarts
/// accumulated replicas — one was found still alive nearly eight hours after
/// the app that spawned it had gone.
///
/// **Why `applicationWillTerminate` and not `scenePhase`.** On macOS
/// `scenePhase` goes `.background` when the last window closes, and closing
/// a window is not quitting — for a headless always-on broadcaster it is the
/// normal state. Tearing the tunnel down there would take the radio off air
/// every time Jonas closed the window, which is the opposite of what this is
/// for. `applicationWillTerminate` fires on genuine termination only: ⌘Q,
/// `osascript quit`, logout, shutdown, and `SIGTERM` from launchd.
///
/// **What it cannot cover.** `SIGKILL` is uncatchable, so this hook is
/// necessarily partial. ``TunnelReaper`` is the other half: on the next
/// launch, orphans left by an unclean exit are found and reaped before a new
/// tunnel starts.
///
/// **Ordering.** It calls `stopAll()`, which is the same path the UI's stop
/// button uses, rather than reaching for `tunnel.stop()` directly. That
/// order matters and already exists: encode loops are cancelled first, then
/// `tearDownListener()` stops the heartbeat, stops the tunnel, cancels the
/// client tasks and their connections, and finally closes the listener.
/// Stopping the tunnel before dropping listeners means in-flight clients
/// lose the far end first, which is the same thing they experience on a
/// deliberate stop today.
final class RatbatAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Already on the main thread — AppKit guarantees it for this
        // callback — and `stopAll()` is MainActor-isolated.
        MainActor.assumeIsolated {
            RadioBroadcaster.current?.stopAll()
        }
    }
}

@main
struct RatbatMacApp: App {
    /// AppKit's termination callback is the only reliable "we are actually
    /// quitting" signal on macOS; SwiftUI's `scenePhase` does not
    /// distinguish quitting from closing a window.
    @NSApplicationDelegateAdaptor(RatbatAppDelegate.self) private var appDelegate
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
