import Foundation

/// Why a candidate was judged to be a mix set. Carried into the audit log so
/// the owner can argue with the call after the fact — which arm fired is the
/// difference between "your threshold is wrong" (duration) and "your word list
/// is wrong" (title).
public enum MixSetVerdict: Sendable, Hashable {
    /// The candidate is at or over the long-form threshold.
    case duration(seconds: TimeInterval)
    /// The candidate's title carried a long-form marker. The associated value
    /// is the literal text as it appeared in the title, not the canonical
    /// pattern — the owner should see what actually matched in their data.
    case title(marker: String)
}

/// Classifies "is this a DJ mix / live set / podcast rather than a track?".
///
/// ## The rule
///
/// A candidate is a mix set if EITHER its duration is >= 20 minutes, OR its
/// title carries an obvious long-form marker. Duration is meant to do the real
/// work; the title patterns exist to catch the 12-minute Boiler Room edit.
///
/// ## Why the title arm is narrower than it first looks
///
/// The intended division of labour only holds where a duration actually
/// arrives before the track is chosen, and measured against the real sources
/// it mostly does not:
///
/// | source   | duration at selection time                                  |
/// |----------|-------------------------------------------------------------|
/// | Bandcamp | yes — `featured_track.duration`, 48/48 fixture items         |
/// | NTS      | key present but `null` on all 21 rows of the tracklist fixture |
/// | Last.fm  | no such field, before or after the fetch                     |
/// | playlist | yes, exact — `Track.duration` from AVFoundation             |
///
/// So on two of the three generative sources the title arm is the *entire*
/// classifier, with nothing to corroborate it. That is why the markers below
/// are split into two tiers. A bare `mix` marker would match the ubiquitous
/// "(Original Mix)" / "(Extended Mix)" version suffix and quietly delete a
/// techno station's core repertoire — normal-length club tracks — on exactly
/// the sources that have no duration to overrule it. The owner's instruction
/// was to be word-boundary aware and not let "set" match "sunset" or "mix"
/// match "mixtape"; this applies that same reasoning to the version suffix,
/// which is the far more common shape.
///
/// The consequence is deliberate and worth stating plainly: an unqualified
/// long DJ mix on NTS or Last.fm whose title says only "Mix" will NOT be
/// caught. Under-firing is the recoverable direction — a mix set that slips
/// through is three minutes of annoyance, whereas a false positive silently
/// removes music the owner wanted and only shows up as a quieter station.
public enum MixSetRule {

    /// 20 minutes. The owner's threshold, and the number they are most likely
    /// to want to argue with — which is why every duration-arm exclusion
    /// records the measured seconds alongside it.
    public static let defaultMinimumDuration: TimeInterval = 20 * 60

    /// Markers unambiguous enough to fire on their own.
    private static let strongMarkers = [
        #"boiler\s+room"#,
        #"live\s+at"#,
        #"podcast"#,
        #"episode"#,
        #"part\s+\d+"#,
    ]

    /// Markers whose bare word is a common false positive on these sources, so
    /// they only fire as part of a qualifying phrase. "Mix" and "set" are the
    /// whole reason this tier exists.
    private static let qualifiedMarkers = [
        #"(?:dj|live|full|opening|closing|guest|warm[\s-]?up)\s+set"#,
        #"(?:dj|continuous|guest|promo)\s+mix"#,
        #"mix\s+set"#,
        #"mixed\s+by"#,
        #"in\s+the\s+mix"#,
        #"b2b"#,
    ]

    /// Compiled once. `\b` on both ends gives the word-boundary behaviour that
    /// keeps "sunset", "mixtape" and "remix" out; the alternation is ordered
    /// longest-first so the reported marker is the most specific match.
    private static let pattern: NSRegularExpression = {
        let alternation = (qualifiedMarkers + strongMarkers).joined(separator: "|")
        // swiftlint:disable:next force_try — the pattern is a literal, and a
        // malformed one is a programmer error that must fail loudly in tests.
        return try! NSRegularExpression(
            pattern: #"\b(?:"# + alternation + #")\b"#,
            options: [.caseInsensitive]
        )
    }()

    /// Returns the verdict, or nil when the candidate is an ordinary track.
    ///
    /// - Parameters:
    ///   - title: candidate title as the source supplies it. May be empty.
    ///   - durationSeconds: nil when the source gives no duration before the
    ///     track is chosen — the NTS and Last.fm case. A nil duration means the
    ///     duration arm cannot fire, NOT that the candidate is short.
    ///   - minimumDuration: the long-form threshold.
    public static func classify(
        title: String,
        durationSeconds: TimeInterval?,
        minimumDuration: TimeInterval = defaultMinimumDuration
    ) -> MixSetVerdict? {
        // Duration first: it is the authoritative arm, and when both would
        // fire the owner is better served by the number than by the word.
        if let durationSeconds, durationSeconds >= minimumDuration {
            return .duration(seconds: durationSeconds)
        }

        guard !title.isEmpty else { return nil }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard
            let match = pattern.firstMatch(in: title, options: [], range: range),
            let matched = Range(match.range, in: title)
        else { return nil }

        return .title(marker: String(title[matched]))
    }
}
