import Foundation

/// Decides whether a tunnel that is *running* has stopped *working*.
///
/// The supervisor already handles a tunnel that dies: `terminationHandler`
/// fires, and it relaunches within about a second. What it cannot see is a
/// tunnel that is alive and not serving. Reproduced on demand with
/// `kill -STOP` on cloudflared: the process stays up, so nothing exits and
/// nothing fires, while from outside the radio is gone.
///
///     before:  public=200
///     t+10s    public=502  local=200
///     t+30s    public=502  local=200
///     t+50s    public=502  local=200
///     t+60s    public=530  local=200   <- Cloudflare "tunnel down"
///     (unfrozen by hand; recovered ~20s later)
///
/// Sixty seconds of the radio being unreachable while every check on the box
/// stayed green, and the app noticing nothing. That is the case this closes.
/// Whether such a wedge has ever happened unprompted in the wild is not
/// established — this is justified by the reproduction, not by a diagnosed
/// past outage.
///
/// A wedge is only visible from outside, so the probe has to leave the
/// machine, cross Cloudflare, and come back through the tunnel. That makes
/// the signal trustworthy and also makes it easy to misread, which is what
/// most of this type is about: the decision to restart is gated on being
/// able to tell "the tunnel is broken" apart from "we are broken", "the
/// internet is gone", and "Cloudflare is having a bad day".
public struct TunnelLiveness: Sendable {

    // MARK: - Inputs

    /// What came back from probing the public hostname.
    public enum PublicOutcome: Sendable, Equatable {
        /// A normal response.
        case ok

        /// Cloudflare answered, but could not get an answer *through* the
        /// tunnel: 530 (its "tunnel is down" code) and the 502/503/504
        /// family. With a healthy origin underneath, this is the wedge
        /// signature.
        case tunnelSuspect(status: Int)

        /// Cloudflare reached the tunnel and the tunnel reached us — and we
        /// returned an error. The tunnel is doing its job; the fault is
        /// ours, and restarting it would fix nothing while adding an outage.
        case originError(status: Int)

        /// Never got as far as an HTTP status: DNS failure, connection
        /// refused, timeout at the socket. The box may simply have no
        /// internet, in which case the tunnel is not the problem and
        /// restarting it is pure superstition.
        case unreachable(reason: String)
    }

    /// One paired observation. Local and public are sampled together on
    /// purpose: neither means much alone.
    public struct Sample: Sendable, Equatable {
        public let at: Double
        /// Did `localhost` serve the same cheap endpoint?
        public let localHealthy: Bool
        public let publicOutcome: PublicOutcome

        public init(at: Double, localHealthy: Bool, publicOutcome: PublicOutcome) {
            self.at = at
            self.localHealthy = localHealthy
            self.publicOutcome = publicOutcome
        }
    }

    // MARK: - Outputs

    public enum Suppression: Sendable, Equatable {
        /// The tunnel is meant to be down. Never fight the owner.
        case tunnelNotRunning
        /// Public is failing and so is local: the fault is ours, not the
        /// tunnel's. Restarting the tunnel would hide nothing and fix
        /// nothing.
        case localAlsoUnhealthy
        /// No route off the machine. A tunnel cannot register with an edge
        /// it cannot reach.
        case networkUnreachable
        /// The request got all the way to us and we answered badly.
        case originFault
        /// A restart just happened; give the edge time to re-register
        /// before judging it again.
        case settling
        /// Backing off between restarts.
        case backingOff
    }

    public enum Decision: Sendable, Equatable {
        case healthy
        /// Failing, but not yet for long enough to act.
        case watching(consecutiveFailures: Int)
        case restart(attempt: Int)
        case suppressed(Suppression)
        /// Escalation exhausted. Stop restarting and say so loudly; a
        /// healthy sample later resets this.
        case gaveUp(afterAttempts: Int)
    }

    // MARK: - Policy

    /// Consecutive bad samples before acting.
    ///
    /// One is noise — an edge hiccup, a lost packet, a probe that raced a
    /// track boundary. Three, at the sampling interval below, means the
    /// tunnel has been unreachable for about a minute and a half, which no
    /// transient explains. The reproduction above was continuously bad from
    /// t+10s to t+60s, so three would have caught it with margin.
    public let failuresBeforeRestart: Int

    /// How long after a restart before samples count again.
    ///
    /// A relaunched cloudflared needs to re-register with the edge before
    /// the public hostname answers. Measured: ~1.1s to respawn, and ~20s
    /// for Cloudflare to route to it again after a replica went away. Sixty
    /// seconds is comfortably past that, so the settling period cannot
    /// itself trigger the next restart.
    public let settleSeconds: Double

    /// Restarts before giving up.
    ///
    /// If five escalating restarts have not fixed it, the problem is not one
    /// we can restart our way out of — most likely Cloudflare itself. With
    /// the backoff below that is roughly half an hour of trying, after which
    /// hammering an edge that is already struggling makes things worse for
    /// everyone.
    public let maxRestarts: Int

    /// First gap between restarts; doubles, capped at ``backoffCap``.
    public let backoffBase: Double
    public let backoffCap: Double

    public init(
        failuresBeforeRestart: Int = 3,
        settleSeconds: Double = 60,
        maxRestarts: Int = 5,
        backoffBase: Double = 60,
        backoffCap: Double = 900
    ) {
        self.failuresBeforeRestart = max(1, failuresBeforeRestart)
        self.settleSeconds = max(0, settleSeconds)
        self.maxRestarts = max(1, maxRestarts)
        self.backoffBase = max(1, backoffBase)
        self.backoffCap = max(backoffBase, backoffCap)
    }

    /// Gap before restart `attempt` (1-based): base, doubling, capped.
    public func backoff(forAttempt attempt: Int) -> Double {
        guard attempt > 1 else { return backoffBase }
        return min(backoffCap, backoffBase * pow(2, Double(attempt - 1)))
    }

    // MARK: - State

    public private(set) var consecutiveFailures = 0
    public private(set) var restartAttempt = 0
    public private(set) var hasGivenUp = false
    private var settlingUntil: Double?
    private var nextRestartAllowedAt: Double?

    // MARK: - The decision

    /// Fold one sample into the state and say what to do.
    ///
    /// - Parameter tunnelRunning: whether the tunnel is supposed to be up at
    ///   all. A deliberate stop, a shutdown, or a tunnel that was never
    ///   started must never be "repaired".
    public mutating func record(
        _ sample: Sample,
        tunnelRunning: Bool
    ) -> Decision {
        // 0. Never fight a deliberate stop.
        guard tunnelRunning else {
            reset()
            return .suppressed(.tunnelNotRunning)
        }

        // 1. A restart in flight: hold judgement until the edge has had time
        //    to re-register, or the settling period itself causes the next
        //    restart.
        if let until = settlingUntil {
            if sample.at < until { return .suppressed(.settling) }
            settlingUntil = nil
        }

        // 2. Classify. Only one shape is the tunnel's fault.
        switch sample.publicOutcome {
        case .ok:
            // A good sample forgives everything, including having given up:
            // a long healthy run means the next fault is a fresh one.
            reset()
            return .healthy

        case .originError:
            // The tunnel delivered the request. Whatever is wrong is behind
            // it, and restarting it would take the radio off air to fix a
            // problem it does not have.
            consecutiveFailures = 0
            return .suppressed(.originFault)

        case .unreachable:
            // Could not get off the box. Cannot distinguish "our tunnel is
            // wedged" from "there is no internet" — and one of those is not
            // improved by a restart, so do nothing.
            consecutiveFailures = 0
            return .suppressed(.networkUnreachable)

        case .tunnelSuspect:
            guard sample.localHealthy else {
                // Both ends failing: the origin is down, so of course the
                // public side is too. This is us.
                consecutiveFailures = 0
                return .suppressed(.localAlsoUnhealthy)
            }
            consecutiveFailures += 1
        }

        // 3. Not yet convinced.
        if consecutiveFailures < failuresBeforeRestart {
            return .watching(consecutiveFailures: consecutiveFailures)
        }

        // 4. Already out of road.
        if hasGivenUp { return .gaveUp(afterAttempts: restartAttempt) }
        if restartAttempt >= maxRestarts {
            hasGivenUp = true
            return .gaveUp(afterAttempts: restartAttempt)
        }

        // 5. Convinced, but too soon since the last attempt.
        if let allowed = nextRestartAllowedAt, sample.at < allowed {
            return .suppressed(.backingOff)
        }

        // 6. Act.
        restartAttempt += 1
        consecutiveFailures = 0
        settlingUntil = sample.at + settleSeconds
        nextRestartAllowedAt = sample.at + backoff(forAttempt: restartAttempt)
        return .restart(attempt: restartAttempt)
    }

    private mutating func reset() {
        consecutiveFailures = 0
        restartAttempt = 0
        hasGivenUp = false
        settlingUntil = nil
        nextRestartAllowedAt = nil
    }

    // MARK: - Classifying a probe result

    /// Map an HTTP status from the public hostname to an outcome.
    ///
    /// 530 is Cloudflare's own "I could not reach the tunnel". 502/503/504
    /// are the same story told by a proxy. Everything else that is an error
    /// got *through* the tunnel to us, which makes it ours.
    public static func classify(publicStatus status: Int) -> PublicOutcome {
        switch status {
        case 200..<400: return .ok
        case 502, 503, 504, 530: return .tunnelSuspect(status: status)
        default: return .originError(status: status)
        }
    }
}
