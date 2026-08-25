import Foundation

/// Wraps a static ``[Track]`` queue and loops forever. By default the
/// queue is shuffled on init and **reshuffled after every full pass**, so
/// each broadcast start picks a fresh random order rather than replaying
/// the same sequence from the same first track every time. Pass
/// `shuffle: false` for deterministic, source-order playback (used by
/// tests and any caller that wants a fixed queue).
///
/// Returning `nil` is reserved for the genuinely empty case — a
/// single-track queue keeps handing back that same track on every call.
public actor PlaylistSource: TrackSource {
    private let shuffle: Bool
    private var order: [Track]
    private var cursor: Int = 0
    /// Records a play and hands back its history row id. A closure, not
    /// a `HistoryStore`: the store is macOS-only and this type is
    /// cross-platform — passing the store itself is the exact shape that
    /// broke the iOS build once. nil on iOS and in tests.
    private let recordPlay: (@Sendable (String, String, URL) async -> Int64?)?
    /// Live read of the mix-set toggle. Read on every call rather than
    /// captured as a value: a playlist has no pool refill to hang a
    /// re-read off, so "the next track" is the only granularity there is.
    private let selectionPolicy: (@Sendable () async -> SelectionPolicy)?
    /// Audit sink for the mix-set rule. Same closure shape and the same
    /// reason as `recordPlay` — and ``SelectionExclusionRecord`` rather
    /// than `HistoryStore.ExclusionInput` because that type lives inside
    /// `#if os(macOS)` and naming it here would break the iOS build.
    private let recordExclusions: (@Sendable ([SelectionExclusionRecord]) async -> Void)?

    public init(
        tracks: [Track],
        shuffle: Bool = true,
        recordPlay: (@Sendable (String, String, URL) async -> Int64?)? = nil,
        selectionPolicy: (@Sendable () async -> SelectionPolicy)? = nil,
        recordExclusions: (@Sendable ([SelectionExclusionRecord]) async -> Void)? = nil
    ) {
        self.shuffle = shuffle
        self.order = shuffle ? tracks.shuffled() : tracks
        self.recordPlay = recordPlay
        self.selectionPolicy = selectionPolicy
        self.recordExclusions = recordExclusions
    }

    public func nextURL() async throws -> TrackSourceItem? {
        guard !order.isEmpty else { return nil }

        let policy = await selectionPolicy?() ?? .default

        // The NEW-VS-OWNED DIAL DOES NOT APPLY HERE, and this early return
        // is deliberate rather than a silent no-op. A playlist station
        // plays the owner's own library: every candidate is owned, so
        // `orderByNewness` would have nothing to choose between, would
        // report a shortfall on every single call, and would fill the
        // audit log with rows saying the dial could not be honoured — for
        // a source where honouring it is meaningless. The mix-set toggle
        // below DOES apply: "a 25-minute ambient record I would have
        // loved" is a record in the owner's own library, which makes this
        // the source where the rule matters most and where the duration is
        // exact rather than inferred.
        let (track, records) = selectNextTrack(policy: policy)

        if let records, !records.isEmpty {
            await recordExclusions?(records)
        }

        // Record the play so your OWN library feeds the same history and
        // taste signals as generative stations. Before this, listening to
        // your own records taught Ratbat nothing and left the history
        // view blank for the station you play most.
        let historyID = await recordPlay?(
            track.artist,
            track.title,
            track.url
        )
        // `album` and `duration` come off the indexed ``Track`` — the
        // library indexer already parsed both out of the file's tags, and
        // dropping them here is what made `/now.json` report `"album": ""`
        // for every library station. An empty album tag means "no album",
        // which the wire says as null rather than "".
        return TrackSourceItem(
            url: track.url,
            artist: track.artist,
            title: track.title,
            album: track.album.isEmpty ? nil : track.album,
            duration: track.duration > 0 ? track.duration : nil,
            origin: .library,
            historyID: historyID,
            isOwned: true
        )
    }

    // MARK: - Selection

    /// Walks the queue until it reaches a track the policy allows, wrapping
    /// and reshuffling as it goes.
    ///
    /// The loop is bounded by the queue length because ``nextURL()``
    /// returning `nil` kills the pipeline: an all-classified queue must
    /// stand down and play something rather than go silent.
    private func selectNextTrack(policy: SelectionPolicy) -> (Track, [SelectionExclusionRecord]?) {
        var records: [SelectionExclusionRecord] = []

        for _ in 0..<order.count {
            advanceCursorWrappingIfNeeded()
            let track = order[cursor]
            cursor += 1

            guard let verdict = MixSetRule.classify(
                title: displayTitle(of: track),
                durationSeconds: track.duration,
                minimumDuration: policy.mixSetMinimumDuration
            ) else {
                return (track, records.isEmpty ? nil : records)
            }

            records.append(record(for: track, verdict: verdict, enforced: policy.excludeMixSets))

            // Classification runs always; only enforcement is conditional.
            // With the toggle off the row above is a shadow record and the
            // track still plays — that is what makes the default-off state
            // useful instead of merely inert.
            if !policy.excludeMixSets {
                return (track, records)
            }
        }

        // Starvation guard: every track in the queue classified. Keeping a
        // mix set is strictly better than a silent station, so stand down,
        // enforce nothing, and say so in a column the reader can reach.
        let unenforced = records.map { row -> SelectionExclusionRecord in
            var copy = row
            copy.enforced = false
            return copy
        }
        let explanation = "stood down: every track in the queue (\(order.count)) classified as a mix set. "
            + "Nothing was dropped — an empty playlist would stop the broadcast."
        let guardRow = SelectionExclusionRecord(
            artist: "",
            title: "",
            arm: SelectionArm.starvationGuard,
            // matchedText, not a `note` column: this is one of the columns
            // `HistoryStore.exclusions(stationID:limit:)` actually returns.
            matchedText: explanation,
            sourceKind: Self.sourceKind,
            enforced: false
        )

        advanceCursorWrappingIfNeeded()
        let track = order[cursor]
        cursor += 1
        return (track, unenforced + [guardRow])
    }

    private func advanceCursorWrappingIfNeeded() {
        guard cursor >= order.count else { return }
        // Completed a full pass. Reshuffle for the next lap so the
        // station doesn't repeat the same order forever, and nudge the
        // seam so a track can't immediately repeat across the wrap.
        if shuffle && order.count > 1 {
            let last = order[order.count - 1]
            order.shuffle()
            if order[0].url == last.url, let swap = order.indices.dropFirst().first {
                order.swapAt(0, swap)
            }
        }
        cursor = 0
    }

    private static let sourceKind = "playlist"

    /// `Track.title` is a non-optional `String` that can still be empty
    /// (files with no tag). The filename is a better thing to show the
    /// owner in the audit log than a blank.
    private func displayTitle(of track: Track) -> String {
        track.title.isEmpty ? track.url.lastPathComponent : track.title
    }

    private func record(
        for track: Track,
        verdict: MixSetVerdict,
        enforced: Bool
    ) -> SelectionExclusionRecord {
        let arm: String
        let matched: String?
        switch verdict {
        case .duration(let seconds):
            arm = SelectionArm.duration
            matched = "\(Int(seconds.rounded()))s"
        case .title(let marker):
            arm = SelectionArm.title
            matched = marker
        }
        return SelectionExclusionRecord(
            artist: track.artist.isEmpty ? "Unknown" : track.artist,
            title: displayTitle(of: track),
            // `Track.duration` is a non-optional `TimeInterval` read from
            // AVFoundation: the EXACT length, not a listing's estimate of
            // one track out of a release. This is the one source where the
            // duration arm measures precisely the thing it removes.
            durationSeconds: track.duration,
            durationSource: "library",
            arm: arm,
            matchedText: matched,
            sourceKind: Self.sourceKind,
            sourceURL: track.url,
            enforced: enforced
        )
    }
}
