#if os(macOS)
import Foundation

/// Why a candidate failed to resolve — and, crucially, whether that says
/// anything about the *station*.
///
/// All three generative controllers used to treat every failure the same
/// way: count it toward a 30-attempt budget and, once spent, throw
/// `poolExhausted`. The source layer maps that to `nil`, and the encode
/// loop reads `nil` as "this station is over" and folds it down.
///
/// So a network blip during a run of yt-dlp calls — 30 timeouts in a row,
/// which is minutes, not hours — was laundered into "the pool is empty"
/// and took the station off air. It stayed off after the network came
/// back, because nothing re-reads a folded station until the next launch.
///
/// A candidate the resolver genuinely cannot use and a machine that
/// briefly cannot reach the internet are different facts and must not
/// share a budget.
public enum ResolveFailureKind: Equatable, Sendable {
    /// This candidate is unusable. The pool is fine; take the next one.
    case genuine
    /// The machine or the network is having a moment. Says nothing about
    /// the pool, and must not count toward declaring it exhausted.
    case transient
}

/// Classify a resolve failure.
///
/// Unknown errors are treated as **transient** on purpose. Getting this
/// wrong in the genuine direction burns the candidate budget and takes a
/// station off air for something that would have healed; getting it wrong
/// in the transient direction only costs a retry.
public func classifyResolveFailure(_ error: Swift.Error) -> ResolveFailureKind {
    if let resolverError = error as? TrackResolver.Error {
        switch resolverError {
        case .noYouTubeMatch:
            // The resolver looked and there is nothing there. Another
            // candidate might do better; this one never will.
            return .genuine
        case .timedOut, .downloadFailed:
            return .transient
        case .venvNotReady, .resolverScriptMissing, .notConfigured:
            // Environment, not candidate. `venvNotReady` in particular is
            // a startup race that resolves itself once the venv finishes
            // bootstrapping — exactly the thing a retry fixes and a
            // budget burn does not.
            return .transient
        }
    }
    if error is URLError { return .transient }
    return .transient
}
#endif
