#if os(macOS)
import SwiftUI
import AppKit

/// First-launch welcome view that asks the user to pick a music folder.
///
/// macOS-only: uses `NSOpenPanel` for folder selection. iOS has no
/// equivalent "pick a folder on disk" affordance, so the iOS variant will
/// be built separately in a later task.
public struct FolderPickerView: View {
    public var onPick: (URL) -> Void

    public init(onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to Ratbat")
                .font(.largeTitle)
            Text("Pick a folder that contains your music.")
                .foregroundStyle(.secondary)
            Button("Pick Music Folder") {
                pickFolder()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }
}
#endif
