import Foundation

/// The two listener preferences that shape what a station chooses to play.
///
/// Deliberately a plain value type with no platform gate and no dependency on
/// the radio types: ``BroadcastPreferences`` is compiled for iOS as well as
/// macOS, so anything it exposes has to build on both. (The selection pipeline
/// itself — `SourceCandidate`, `FacetedPipeline` — is inside `#if os(macOS)`.
/// Naming those types here would break the `RatbatIOS` CI step, which is why
/// ``SelectionOrdering/orderByNewness(_:share:phase:isNew:)`` is generic over a
/// closure instead of taking a candidate type.)
public struct SelectionPolicy: Sendable, Hashable, Codable {

    /// Target share of plays that should be music the owner does not already
    /// own, in [0, 1]. See ``SelectionOrdering/orderByNewness(_:share:phase:isNew:)``
    /// for exactly what "share" means — it is a deterministic ratio over plays,
    /// not a per-track coin flip.
    ///
    /// `nil` means "no preference — leave the upstream ranking alone", and is
    /// what ships. It is deliberately NOT the same as 0.0: a 0.0 dial is an
    /// active reorder that leads with owned music and appends new, so shipping
    /// 0.0 would change what an existing listener hears. `nil` is the only
    /// value that is genuinely inert, and the mechanism stays dormant behind
    /// it until the owner sets a value in Settings.
    public var newMusicShare: Double?

    /// When true, candidates classified by ``MixSetRule`` are removed from the
    /// pool before selection. When false the classification still runs and is
    /// still recorded, but nothing is dropped — that shadow record is what
    /// makes the default-off state useful rather than merely inert.
    public var excludeMixSets: Bool

    /// Long-form threshold handed to ``MixSetRule``.
    public var mixSetMinimumDuration: TimeInterval

    /// Ships inert: no dial, no mix-set filtering. An owner who upgrades and
    /// touches nothing hears exactly what they heard before.
    public static let `default` = SelectionPolicy(
        newMusicShare: nil,
        excludeMixSets: false,
        mixSetMinimumDuration: MixSetRule.defaultMinimumDuration
    )

    /// `newMusicShare` is clamped here rather than at the call sites so a bad
    /// value cannot reach the ordering, whatever wrote it. `nil` passes
    /// through untouched — it means "off", not "zero".
    public init(
        newMusicShare: Double? = nil,
        excludeMixSets: Bool = false,
        mixSetMinimumDuration: TimeInterval = MixSetRule.defaultMinimumDuration
    ) {
        self.newMusicShare = newMusicShare.map { min(1, max(0, $0)) }
        self.excludeMixSets = excludeMixSets
        self.mixSetMinimumDuration = mixSetMinimumDuration
    }
}

/// Result of applying the new-vs-owned dial to a candidate pool.
public struct NewnessOrdering<Candidate>: Sendable where Candidate: Sendable {
    /// The reordered pool. Always a permutation of the input — same elements,
    /// same count.
    public let ordered: [Candidate]
    /// How many candidates counted as new.
    public let newSupply: Int
    /// How many counted as owned.
    public let ownedSupply: Int
    /// How many times the dial asked for one bucket and had to be served from
    /// the other because the preferred one was empty. Non-zero means the
    /// realised ratio will not match the requested one, and the owner should be
    /// told rather than left thinking the dial does nothing.
    public let shortfall: Int
}

public enum SelectionOrdering {

    /// The one artist-key rule. Ownership matching, the phase counters and any
    /// library index must all use this, so they cannot drift apart.
    ///
    /// Note this is artist-level, and that is the honest limit of what the
    /// codebase can answer: `TasteProfile.libraryContainsArtist` is the only
    /// library-membership test that exists, and there is no artist+title
    /// lookup anywhere. "New" therefore means "you own nothing by this
    /// artist", not "you don't have this track" — the UI copy must say so.
    public static func artistKey(_ artist: String) -> String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Reorders a ranked candidate pool so that, over the plays that follow,
    /// roughly `share` of them are new.
    ///
    /// ## What "share" means, precisely
    ///
    /// A deterministic quota over play order, not a probability. Walking the
    /// output, at every prefix of length k the number of new candidates stays
    /// within 1 of `share * k` for as long as both buckets have supply. At 0.7
    /// that means the listener cannot hit a run of six owned tracks by bad
    /// luck, which a per-track coin flip would happily produce.
    ///
    /// ## Why it reorders instead of filtering
    ///
    /// This function never removes a candidate. That is the property that
    /// makes the dial safe at both ends: a 100% setting over a pool with no
    /// new music yields every owned track (in order) and a non-zero
    /// ``NewnessOrdering/shortfall``, rather than an empty pool and a silent
    /// station. Filtering after selection produces gaps and repeats; choosing
    /// correctly does not.
    ///
    /// - Parameters:
    ///   - phase: `(new, total)` plays realised so far on this station. Carried
    ///     across refills so that candidates rejected *after* ordering — already
    ///     played, resolve failed — are corrected for at the next refill rather
    ///     than accumulating as permanent drift.
    ///   - isNew: ownership test, called once per candidate.
    public static func orderByNewness<Candidate>(
        _ candidates: [Candidate],
        share: Double,
        phase: (new: Int, total: Int) = (0, 0),
        isNew: (Candidate) -> Bool
    ) -> NewnessOrdering<Candidate> {
        let target = min(1, max(0, share))

        // Stable partition: rank order inside each bucket is preserved, so the
        // upstream taste scoring still decides *which* new track plays first.
        var newBucket: [Candidate] = []
        var ownedBucket: [Candidate] = []
        for candidate in candidates {
            if isNew(candidate) { newBucket.append(candidate) } else { ownedBucket.append(candidate) }
        }

        var ordered: [Candidate] = []
        ordered.reserveCapacity(candidates.count)
        var newIndex = 0, ownedIndex = 0, shortfall = 0
        var playedNew = phase.new
        var playedTotal = phase.total

        for _ in 0..<candidates.count {
            // Bresenham-style deficit test: are we behind the quota if we count
            // this slot? Ties resolve toward owned, so share 0 never serves new.
            let newIsDue = Double(playedNew) < target * Double(playedTotal + 1)

            if newIsDue {
                if newIndex < newBucket.count {
                    ordered.append(newBucket[newIndex]); newIndex += 1; playedNew += 1
                } else if ownedIndex < ownedBucket.count {
                    ordered.append(ownedBucket[ownedIndex]); ownedIndex += 1; shortfall += 1
                }
            } else {
                if ownedIndex < ownedBucket.count {
                    ordered.append(ownedBucket[ownedIndex]); ownedIndex += 1
                } else if newIndex < newBucket.count {
                    ordered.append(newBucket[newIndex]); newIndex += 1; playedNew += 1; shortfall += 1
                }
            }
            playedTotal += 1
        }

        return NewnessOrdering(
            ordered: ordered,
            newSupply: newBucket.count,
            ownedSupply: ownedBucket.count,
            shortfall: shortfall
        )
    }
}
