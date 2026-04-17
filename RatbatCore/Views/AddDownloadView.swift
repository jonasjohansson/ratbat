#if os(macOS)
import SwiftUI

/// Modal sheet that lets the user paste a Spotify URL and pick a destination
/// subfolder inside the library root, then hands the request off to
/// ``DownloadService/enqueue(spotifyURL:destination:)``.
///
/// Wired from ``RootView``'s toolbar `+` button in Task 2b. Setup progress
/// (first-run Python/venv install) surfaces inline so users don't have to
/// dismiss the sheet to see what's happening.
///
/// No Downloads sidebar yet — that's Task 2c. This view just fires the
/// enqueue and dismisses; observers read `downloadService.batches` elsewhere.
public struct AddDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var downloadService: DownloadService
    public let libraryFolder: URL

    @State private var url: String = ""
    @State private var destinationChoice: DestinationChoice = .newFolder
    @State private var newFolderName: String = ""
    @State private var existingSubfolder: URL?
    @State private var existingSubfolders: [URL] = []
    @State private var isSubmitting = false
    @State private var submitError: String?

    public enum DestinationChoice: Hashable {
        case newFolder
        case existing
    }

    public init(downloadService: DownloadService, libraryFolder: URL) {
        self.downloadService = downloadService
        self.libraryFolder = libraryFolder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download from Spotify")
                .font(.title3).fontWeight(.semibold)

            Text("Paste a Spotify playlist or track URL. Tracks download to a folder in your library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Spotify URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://open.spotify.com/playlist/...", text: $url)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination").font(.caption).foregroundStyle(.secondary)
                Picker("Destination", selection: $destinationChoice) {
                    Text("New folder").tag(DestinationChoice.newFolder)
                    if !existingSubfolders.isEmpty {
                        Text("Existing folder").tag(DestinationChoice.existing)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch destinationChoice {
                case .newFolder:
                    TextField("Folder name (e.g. Recordify)", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                case .existing:
                    Picker("Folder", selection: $existingSubfolder) {
                        Text("Choose a folder…").tag(URL?.none)
                        ForEach(existingSubfolders, id: \.path) { folder in
                            Text(folder.lastPathComponent).tag(URL?.some(folder))
                        }
                    }
                    .labelsHidden()
                }
            }

            // Setup progress / errors appear here
            setupStatusRow

            if let submitError {
                Label(submitError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { Task { await start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            await loadExistingFolders()
            await downloadService.checkSetup()
        }
    }

    @ViewBuilder
    private var setupStatusRow: some View {
        switch downloadService.setupState {
        case .installing(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard URL(string: url.trimmingCharacters(in: .whitespaces)) != nil else { return false }
        switch destinationChoice {
        case .newFolder:
            return !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty
        case .existing:
            return existingSubfolder != nil
        }
    }

    private func loadExistingFolders() async {
        let folders: [URL] = await Task.detached { [libraryFolder] in
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: libraryFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return contents.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        }.value
        existingSubfolders = folders
    }

    private func start() async {
        submitError = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard let spotifyURL = URL(string: trimmedURL) else {
            submitError = "Invalid URL"
            return
        }

        let destination: URL
        switch destinationChoice {
        case .newFolder:
            let name = newFolderName.trimmingCharacters(in: .whitespaces)
            destination = libraryFolder.appendingPathComponent(name)
        case .existing:
            guard let existing = existingSubfolder else {
                submitError = "Pick a folder"
                return
            }
            destination = existing
        }

        do {
            _ = try await downloadService.enqueue(spotifyURL: spotifyURL, destination: destination)
            dismiss()
        } catch {
            submitError = error.localizedDescription
        }
    }
}
#endif
