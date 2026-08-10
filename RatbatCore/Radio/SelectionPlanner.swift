import Foundation

/// One audited selection decision, in a form every source can produce.
///
/// A structural twin of `HistoryStore.ExclusionInput` rather than the type
/// itself, and deliberately so: `ExclusionInput` lives inside
/// `#if os(macOS)`, while ``PlaylistSource`` — one of the four sources that
/// has to emit these — is cross-platform. Naming the macOS type in a
/// cross-platform signature is the exact shape that broke the iOS build
/// once (see ``PlaylistSource``'s own comment on `recordPlay`). On macOS an
/// adapter maps this to `ExclusionInput` at the store boundary.
public struct SelectionExclusionRecord: Sendable, Hashable {
    public var artist: String
    public var title: String
    public var durationSeconds: Double?
    public var durationSource: String?
    public var arm: String
    /// Doubles as the human-readable explanation on the station-level rows
    /// (``SelectionArm/starvationGuard``, ``SelectionArm/shortfall``). It is
    /// a column `HistoryStore.exclusions(stationID:limit:)` actually
    /// returns — an earlier design wrote the explanation into a `note`
    /// column no read surface ever displayed.
    public var matchedText: String?
    public var sourceKind: String
    public var sourceURL: URL?
    public var enforced: Bool

    public init(
        artist: String,
        title: String,
        durationSeconds: Double? = nil,
        durationSource: String? = nil,
        arm: String,
        matchedText: String? = nil,
        sourceKind: String,
        sourceURL: URL? = nil,
        enforced: Bool
    ) {
        self.artist = artist
        self.title = title
        self.durationSeconds = durationSeconds
        self.durationSource = durationSource
        self.arm = arm
        self.matchedText = matchedText
        self.sourceKind = sourceKind
        self.sourceURL = sourceURL
        self.enforced = enforced
    }
}

/// The `arm` vocabulary. The first two are rule verdicts; the last two are
/// station-level explanations. All four are distinct values because
/// `selection_exclusions` is unique on `(station_id, artist_norm,
/// title_norm, arm)` and the station-level rows share an empty
/// artist/title — a shared arm would collapse them onto each other.
public enum SelectionArm {
    public static let duration = "duration"
    public static let title = "title"
    /// The mix-set filter would have emptied the pool, so it stood down.
    public static let starvationGuard = "starvation-guard"
    /// The dial asked for a bucket that had no supply.
    public static let shortfall = "shortfall"
}

/// What the planner needs to know about one candidate. Sources differ
/// wildly in what they can answer here — Bandcamp has a duration for the
/// featured track, a playlist has the exact file length, NTS and Last.fm
/// have nothing — so the shape is deliberately the intersection.
public struct SelectionSubject: Sendable, Hashable {
    public var artist: String
    public var title: String
    /// `nil` means the source gave NO duration before the track was chosen.
    /// It does not mean "short" — see ``MixSetRule/classify(title:durationSeconds:minimumDuration:)``.
    public var durationSeconds: TimeInterval?
    /// Where that number came from. `nil` alongside a `nil` duration.
    public var durationSource: String?
    public var sourceURL: URL?

    public init(
        artist: String,
        title: String,
        durationSeconds: TimeInterval? = nil,
        durationSource: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.artist = artist
        self.title = title
        self.durationSeconds = durationSeconds
        self.durationSource = durationSource
        self.sourceURL = sourceURL
    }
}

/// A candidate paired with the facts the planner needs about it.
///
/// Exists so a caller inside an actor can build every ``SelectionSubject``
/// up front — while it is already on its own executor and its side tables
/// are in reach — instead of handing the planner a closure that reaches
/// back into actor-isolated state from a `nonisolated` context.
public struct SelectionInput<Candidate: Sendable>: Sendable {
    public let candidate: Candidate
    public let subject: SelectionSubject

    public init(candidate: Candidate, subject: SelectionSubject) {
        self.candidate = candidate
        self.subject = subject
    }
}

/// Outcome of the mix-set stage alone.
public struct MixSetFilterResult<Candidate: Sendable>: Sendable {
    public let kept: [Candidate]
    public let exclusions: [SelectionExclusionRecord]
    /// True when enforcement would have emptied the pool and the filter
    /// stood down. Nothing was dropped, and no row claims otherwise.
    public let stoodDown: Bool
}

/// Outcome of the full stage: mix-set filter, then the dial.
public struct SelectionPlan<Candidate: Sendable>: Sendable {
    public let ordered: [Candidate]
    public let exclusions: [SelectionExclusionRecord]
    public let shortfall: Int
    public let stoodDown: Bool
}

/// Applies a ``SelectionPolicy`` to a candidate pool.
///
/// Pure, generic over the candidate type and NOT platform-gated, for three
/// reasons: the playlist source that calls it compiles for iOS; the real
/// candidate type (`SourceCandidate`) is macOS-only; and it makes the whole
/// policy step testable without a network stub or a live controller.
///
/// The station must not pick a track and then filter it out afterwards —
/// filtering after selection produces gaps and repeats. Everything here
/// happens while the pool is being built.
public enum SelectionPlanner {

    /// Classification runs ALWAYS. Enforcement — actual removal — only when
    /// `policy.excludeMixSets` is true; otherwise the verdict is still
    /// recorded with `enforced: false`. That shadow record is what makes
    /// the default-off state useful rather than merely inert: the owner can
    /// see what the rule WOULD have taken before they trust it with the
    /// toggle.
    ///
    /// Only candidates that classify are recorded. The pool at large is not
    /// logged — an audit trail of everything is an audit trail of nothing.
    public static func filterMixSets<Candidate: Sendable>(
        _ candidates: [Candidate],
        policy: SelectionPolicy,
        sourceKind: String,
        subject: (Candidate) -> SelectionSubject
    ) -> MixSetFilterResult<Candidate> {
        var kept: [Candidate] = []
        kept.reserveCapacity(candidates.count)
        var rows: [SelectionExclusionRecord] = []

        for candidate in candidates {
            let s = subject(candidate)
            guard let verdict = MixSetRule.classify(
                title: s.title,
                durationSeconds: s.durationSeconds,
                minimumDuration: policy.mixSetMinimumDuration
            ) else {
                kept.append(candidate)
                continue
            }

            let arm: String
            let matched: String?
            switch verdict {
            case .duration(let seconds):
                arm = SelectionArm.duration
                matched = "\(Int(seconds.rounded()))s ≥ \(Int(policy.mixSetMinimumDuration.rounded()))s"
            case .title(let marker):
                arm = SelectionArm.title
                matched = marker
            }

            rows.append(SelectionExclusionRecord(
                artist: s.artist,
                title: s.title,
                durationSeconds: s.durationSeconds,
                durationSource: s.durationSource,
                arm: arm,
                matchedText: matched,
                sourceKind: sourceKind,
                sourceURL: s.sourceURL,
                enforced: policy.excludeMixSets
            ))

            if !policy.excludeMixSets {
                kept.append(candidate)
            }
        }

        // Starvation guard. The toggle removes; a pool it emptied is a
        // silent station, which is strictly worse than a mix set. Stand
        // down: keep every candidate, enforce nothing, and leave an
        // explanation the reader can actually reach.
        if kept.isEmpty && !candidates.isEmpty {
            let unenforced = rows.map { row -> SelectionExclusionRecord in
                var copy = row
                copy.enforced = false
                return copy
            }
            let explanation = "stood down: enforcing the mix-set rule would have emptied the pool "
                + "(\(candidates.count) candidate(s), all classified). Nothing was dropped."
            return MixSetFilterResult(
                kept: candidates,
                exclusions: unenforced + [SelectionExclusionRecord(
                    artist: "",
                    title: "",
                    arm: SelectionArm.starvationGuard,
                    matchedText: explanation,
                    sourceKind: sourceKind,
                    enforced: false
                )],
                stoodDown: true
            )
        }

        return MixSetFilterResult(kept: kept, exclusions: rows, stoodDown: false)
    }

    /// The full selection stage for a GENERATIVE source: mix-set filter,
    /// then the new-vs-owned dial.
    ///
    /// Order matters. The dial runs last so its quota survives — reordering
    /// and then removing would break the ratio the ordering just
    /// established.
    ///
    /// - Parameters:
    ///   - phase: `(new, total)` plays realised on this station so far.
    ///     Carried across refills so candidates rejected AFTER ordering
    ///     (already played, resolve failed) self-correct instead of
    ///     drifting.
    ///   - ownedArtistKeys: from `TasteProfile.ownedArtistKeys()`, fetched
    ///     ONCE per refill. Passing a set rather than an ownership closure
    ///     keeps this to one actor hop instead of one per candidate, and
    ///     lets the caller reuse the very same set for its phase counters
    ///     so ownership matching and the counters cannot drift.
    public static func plan<Candidate: Sendable>(
        _ candidates: [Candidate],
        policy: SelectionPolicy,
        phase: (new: Int, total: Int),
        sourceKind: String,
        ownedArtistKeys: Set<String>,
        subject: (Candidate) -> SelectionSubject
    ) -> SelectionPlan<Candidate> {
        let filtered = filterMixSets(
            candidates,
            policy: policy,
            sourceKind: sourceKind,
            subject: subject
        )

        let ordering = SelectionOrdering.orderByNewness(
            filtered.kept,
            share: policy.newMusicShare,
            phase: phase,
            isNew: { !ownedArtistKeys.contains(SelectionOrdering.artistKey(subject($0).artist)) }
        )

        var rows = filtered.exclusions
        if ordering.shortfall > 0 {
            // The dial never removes, so this drops nothing — but without
            // it "my 100% dial does nothing" has no answer on disk.
            let explanation = "dial shortfall: asked for \(Int((policy.newMusicShare * 100).rounded()))% new "
                + "over \(ordering.newSupply) new / \(ordering.ownedSupply) owned candidate(s); "
                + "\(ordering.shortfall) slot(s) served from the other bucket."
            rows.append(SelectionExclusionRecord(
                artist: "",
                title: "",
                arm: SelectionArm.shortfall,
                matchedText: explanation,
                sourceKind: sourceKind,
                enforced: false
            ))
        }

        return SelectionPlan(
            ordered: ordering.ordered,
            exclusions: rows,
            shortfall: ordering.shortfall,
            stoodDown: filtered.stoodDown
        )
    }
}
