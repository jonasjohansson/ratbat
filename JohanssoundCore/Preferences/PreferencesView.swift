#if os(macOS)
import SwiftUI

/// Standard macOS Settings pane exposing the configurable subset of
/// ``BroadcastPreferences``. Wired from the app's `Settings` scene, so
/// ⌘, opens it from anywhere in the app.
///
/// Layout follows the platform convention: a `TabView` of named tabs
/// (only one right now — Broadcast — but leaves room for future Library /
/// Tunnel tabs without restructuring), each tab rendered as a grouped
/// `Form` so labels and controls align naturally.
///
/// A compact "restart to apply" banner appears when the parent has
/// flagged ``needsRestart``. That signal lives on the broadcaster, not on
/// the preferences, so the view just receives it as a plain Bool.
public struct PreferencesView: View {
    @ObservedObject public var preferences: BroadcastPreferences
    public var needsRestart: Bool

    public init(
        preferences: BroadcastPreferences = .shared,
        needsRestart: Bool = false
    ) {
        self.preferences = preferences
        self.needsRestart = needsRestart
    }

    public var body: some View {
        TabView {
            broadcastTab
                .tabItem {
                    Label("Broadcast", systemImage: "antenna.radiowaves.left.and.right")
                }
        }
        .frame(width: 480, height: 340)
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
