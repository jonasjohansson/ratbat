#if os(macOS)
import SwiftUI
import AppKit

/// Standard macOS Settings pane exposing the configurable subset of
/// ``BroadcastPreferences`` plus the Library folder path. Wired from
/// the app's `Settings` scene, so ⌘, opens it from anywhere in the app.
///
/// Layout follows the platform convention: a `TabView` of named tabs,
/// each tab rendered as a grouped `Form` so labels and controls align
/// naturally.
///
/// A compact "restart to apply" banner appears when the parent has
/// flagged ``needsRestart``. That signal lives on the broadcaster, not on
/// the preferences, so the view just receives it as a plain Bool.
public struct PreferencesView: View {
    @ObservedObject public var preferences: BroadcastPreferences
    /// Optional so tests / previews that don't care about the Library tab
    /// can still construct the view. When nil the tab renders a hint
    /// instead of the folder controls.
    @ObservedObject public var libraryConfig: LibraryConfig
    public var needsRestart: Bool

    public init(
        preferences: BroadcastPreferences = .shared,
        libraryConfig: LibraryConfig = LibraryConfig(),
        needsRestart: Bool = false
    ) {
        self.preferences = preferences
        self.libraryConfig = libraryConfig
        self.needsRestart = needsRestart
    }

    public var body: some View {
        TabView {
            broadcastTab
                .tabItem {
                    Label("Broadcast", systemImage: "antenna.radiowaves.left.and.right")
                }
            libraryTab
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }
            lastFMTab
                .tabItem {
                    Label("Last.fm", systemImage: "chart.bar")
                }
        }
        .frame(width: 520, height: 360)
        .padding()
    }

    @ViewBuilder
    private var broadcastTab: some View {
        Form {
            Section("Audio Quality") {
                Picker("Quality:", selection: qualityBinding) {
                    ForEach(AudioQuality.allCases, id: \.self) { q in
                        Text(q.label).tag(q)
                    }
                }
                Picker("Sample Rate:", selection: sampleRateBinding) {
                    ForEach(SampleRate.allCases, id: \.self) { r in
                        Text(r.label).tag(r)
                    }
                }
            }
            Section("Network") {
                HStack {
                    Text("Port:")
                    TextField("", value: $preferences.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Spacer()
                }
                Toggle("Include track info (ICY metadata)", isOn: $preferences.icyMetadataEnabled)
            }
            Section("Owner Key") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(preferences.ownerToken)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(preferences.ownerToken, forType: .string)
                        }
                    }
                    Text("♥ / skip / next on the web player require this key — open ratbat.jonasjohansson.se#key=<key> once per device to unlock. Without it, listeners get a radio, not a mixer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Auto-start") {
                if preferences.autoStartSlugs.isEmpty {
                    Text("No stations auto-start. Right-click a station in the sidebar → “Auto-start on Launch”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.autoStartSlugs, id: \.self) { slug in
                        Text(slug)
                            .font(.caption.monospaced())
                    }
                    Text("These stations go live at launch. Idle stations cost nothing — the encoder sleeps until someone tunes in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if needsRestart {
                Section {
                    Label(
                        "Restart broadcast to apply changes",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var libraryTab: some View {
        Form {
            Section("Music Folder") {
                VStack(alignment: .leading, spacing: 6) {
                    if let url = libraryConfig.musicFolder {
                        Text(url.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("No folder picked yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Change…") { pickMusicFolder() }
                        Button("Reload Library") { libraryConfig.requestReload() }
                            .disabled(libraryConfig.musicFolder == nil)
                    }
                }
            }
            Section {
                Text("""
                Changing folders re-scans the library in place and re-points \
                every playlist-backed station. Stations persist to \
                `.ratbat-stations.json` next to the selected folder, so \
                stations created against the previous folder will not appear \
                until you point the app back at that folder.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Show a folder picker and, on OK, assign the new URL through the
    /// `@Published` `musicFolder` setter. `RootView` observes the same
    /// `LibraryConfig`, so it re-fires its library-load task automatically.
    private func pickMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let current = libraryConfig.musicFolder {
            panel.directoryURL = current
        }
        if panel.runModal() == .OK, let url = panel.url {
            libraryConfig.musicFolder = url
        }
    }

    @ViewBuilder
    private var lastFMTab: some View {
        Form {
            Section("API Key") {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Paste Last.fm API key…", text: $preferences.lastFMAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Text(preferences.lastFMAPIKey.isEmpty
                         ? "Register a free key at last.fm/api/account/create and paste it here — Last.fm-backed stations won't play until one is set."
                         : "Stored in UserDefaults. Clearing this field disables Last.fm stations on the next broadcast start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Button {
                    if let url = URL(string: "https://www.last.fm/api/account/create") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Register a key at last.fm", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
    }

    // `@AppStorage`-backed computed properties can't be bound directly with
    // the `$` shortcut, so hand-roll bindings that read/write through the
    // preferences object. Each write triggers the `revision` tick via the
    // setter, which is what we want.
    private var qualityBinding: Binding<AudioQuality> {
        Binding(
            get: { preferences.quality },
            set: { preferences.quality = $0 }
        )
    }

    private var sampleRateBinding: Binding<SampleRate> {
        Binding(
            get: { preferences.sampleRate },
            set: { preferences.sampleRate = $0 }
        )
    }
}
#endif
