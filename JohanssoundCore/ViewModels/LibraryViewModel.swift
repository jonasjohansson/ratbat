import Foundation
import SwiftUI

/// Drives ``LibraryView`` by running a ``LibraryIndexer`` scan and publishing
/// the resulting tracks, loading state, and any error.
///
/// `@MainActor` because it publishes UI state. Deliberately narrow: no
/// persistence, no hot-reload, no file-system notifications — just "given a
/// folder, produce tracks". Wider behaviour can layer on in later tasks.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var tracks: [Track] = []
    @Published public var isLoading = false
    @Published public var error: String?

    private let indexer: LibraryIndexer

    public init(indexer: LibraryIndexer = LibraryIndexer()) {
        self.indexer = indexer
    }

    /// Scan `folder` and publish the results. On failure, clears `tracks`
    /// and populates `error` with a user-presentable description.
    public func load(from folder: URL) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            tracks = try await indexer.scan(folder: folder)
        } catch {
            self.error = error.localizedDescription
            tracks = []
        }
    }
}
