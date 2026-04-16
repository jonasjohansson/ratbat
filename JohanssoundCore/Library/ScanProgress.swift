import Foundation

/// Phase-aware progress signal emitted by ``LibraryIndexer/scan(folder:progress:)``.
///
/// Task 1.14 split the flat `(current, total)` callback into two phases so
/// the UI can show forward motion *before* the metadata pass even starts.
/// On large libraries (10k+ files) the file-tree walk alone takes seconds,
/// during which the old API couldn't say anything — the spinner just sat
/// there. Now Phase 1 publishes a running "folders found / files found"
/// count while enumerating, and Phase 2 takes over with the familiar
/// "processed / total" once the tree is locked.
///
/// `Equatable` (auto-synth) so `@Published` bindings diff cleanly in
/// SwiftUI. `Sendable` because the callback runs on an actor-hopping
/// boundary between the indexer's task tree and the main actor.
public enum ScanPhase: Sendable, Equatable {
    /// Phase 1: walking the folder tree, counting folders and audio files.
    /// Total is unknown until Phase 1 completes — the UI should render the
    /// live counts without a denominator.
    case discovering(foldersFound: Int, filesFound: Int)

    /// Phase 2: loading metadata in parallel. Total is locked to the Phase 1
    /// file count; `processed` ticks up as each AVFoundation load completes.
    case loading(processed: Int, total: Int)
}
