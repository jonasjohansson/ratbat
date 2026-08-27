import XCTest
@testable import RatbatCore

/// The liveness monitor restarts the tunnel, which takes the radio (and
/// anything else sharing that tunnel) off air for a few seconds. So these
/// tests are mostly about the cases where it must **refuse** to act.
///
/// The case it exists for was reproduced with `kill -STOP` on cloudflared:
/// the process stays alive so nothing exits, while from outside the radio is
/// gone — 60s of public 502/530 against local 200, with the app noticing
/// nothing.
final class TunnelLivenessTests: XCTestCase {

    private func wedged(_ t: Double, status: Int = 530) -> TunnelLiveness.Sample {
        .init(at: t, localHealthy: true, publicOutcome: .tunnelSuspect(status: status))
    }
    private func healthy(_ t: Double) -> TunnelLiveness.Sample {
        .init(at: t, localHealthy: true, publicOutcome: .ok)
    }

    /// Feed samples every 30s and collect decisions.
    @discardableResult
    private func run(
        _ m: inout TunnelLiveness,
        _ samples: [TunnelLiveness.Sample],
        tunnelRunning: Bool = true
    ) -> [TunnelLiveness.Decision] {
        samples.map { m.record($0, tunnelRunning: tunnelRunning) }
    }

    // MARK: - The case it exists for

    func testRestartsAfterSustainedPublicFailureWithHealthyLocal() {
        var m = TunnelLiveness()
        let d = run(&m, [wedged(0), wedged(30), wedged(60)])
        XCTAssertEqual(d[0], .watching(consecutiveFailures: 1))
        XCTAssertEqual(d[1], .watching(consecutiveFailures: 2))
        XCTAssertEqual(d[2], .restart(attempt: 1), "3 consecutive = ~90s of unreachable")
    }

    func testTheReproducedWedgeSignatureTriggersIt() {
        // Exactly what kill -STOP produced: 502s giving way to 530.
        var m = TunnelLiveness()
        let d = run(&m, [wedged(0, status: 502), wedged(30, status: 502), wedged(60, status: 530)])
        XCTAssertEqual(d.last, .restart(attempt: 1))
    }

    // MARK: - Refusals

    /// Both ends down means the origin is down, so of course the public side
    /// is. Restarting the tunnel fixes nothing and costs an outage.
    func testRefusesWhenLocalIsAlsoUnhealthy() {
        var m = TunnelLiveness()
        let bothDown = (0..<10).map {
            TunnelLiveness.Sample(at: Double($0) * 30, localHealthy: false,
                                  publicOutcome: .tunnelSuspect(status: 530))
        }
        let d = run(&m, bothDown)
        XCTAssertTrue(d.allSatisfy { $0 == .suppressed(.localAlsoUnhealthy) })
        XCTAssertEqual(m.restartAttempt, 0, "never restarted")
    }

    /// No route off the box. A tunnel cannot register with an edge it cannot
    /// reach, so a restart is superstition.
    func testRefusesWhenTheBoxHasNoInternet() {
        var m = TunnelLiveness()
        let offline = (0..<10).map {
            TunnelLiveness.Sample(at: Double($0) * 30, localHealthy: true,
                                  publicOutcome: .unreachable(reason: "nodename nor servname provided"))
        }
        let d = run(&m, offline)
        XCTAssertTrue(d.allSatisfy { $0 == .suppressed(.networkUnreachable) })
        XCTAssertEqual(m.restartAttempt, 0)
    }

    /// The request reached us and we answered badly — the tunnel worked.
    func testRefusesWhenTheFaultIsOurOwnOrigin() {
        var m = TunnelLiveness()
        let d = run(&m, (0..<10).map {
            TunnelLiveness.Sample(at: Double($0) * 30, localHealthy: true,
                                  publicOutcome: .originError(status: 500))
        })
        XCTAssertTrue(d.allSatisfy { $0 == .suppressed(.originFault) })
        XCTAssertEqual(m.restartAttempt, 0)
    }

    /// Never fight a deliberate stop or a shutdown.
    func testRefusesWhileTheTunnelIsDeliberatelyStopped() {
        var m = TunnelLiveness()
        let d = run(&m, [wedged(0), wedged(30), wedged(60), wedged(90)], tunnelRunning: false)
        XCTAssertTrue(d.allSatisfy { $0 == .suppressed(.tunnelNotRunning) })
        XCTAssertEqual(m.restartAttempt, 0)
    }

    /// Intermittent badness is not a wedge; the counter must not accumulate
    /// across good samples.
    func testFlappingNeverReachesTheThreshold() {
        var m = TunnelLiveness()
        var t = 0.0
        for _ in 0..<12 {
            _ = m.record(wedged(t), tunnelRunning: true);  t += 30
            _ = m.record(wedged(t), tunnelRunning: true);  t += 30
            let d = m.record(healthy(t), tunnelRunning: true); t += 30
            XCTAssertEqual(d, .healthy)
        }
        XCTAssertEqual(m.restartAttempt, 0, "two-bad-then-good must never restart")
    }

    func testASingleBadSampleIsIgnored() {
        var m = TunnelLiveness()
        XCTAssertEqual(m.record(wedged(0), tunnelRunning: true), .watching(consecutiveFailures: 1))
        XCTAssertEqual(m.record(healthy(30), tunnelRunning: true), .healthy)
        XCTAssertEqual(m.consecutiveFailures, 0)
    }

    // MARK: - Not looping

    /// A Cloudflare-wide incident looks like a permanent wedge. Escalate,
    /// then stop — do not hammer an edge that is already struggling.
    func testCloudflareWideOutageEscalatesThenGivesUpAndStays() {
        var m = TunnelLiveness(failuresBeforeRestart: 3, settleSeconds: 60,
                               maxRestarts: 5, backoffBase: 60, backoffCap: 900)
        var t = 0.0
        var restarts = 0
        var gaveUp = false
        // Twelve hours of unbroken failure.
        while t < 12 * 3600 {
            switch m.record(wedged(t), tunnelRunning: true) {
            case .restart: restarts += 1
            case .gaveUp: gaveUp = true
            default: break
            }
            t += 30
        }
        XCTAssertEqual(restarts, 5, "capped at maxRestarts however long it lasts")
        XCTAssertTrue(gaveUp)
    }

    func testDoesNotRestartAgainWhileSettling() {
        var m = TunnelLiveness(failuresBeforeRestart: 3, settleSeconds: 60)
        XCTAssertEqual(m.record(wedged(0), tunnelRunning: true), .watching(consecutiveFailures: 1))
        XCTAssertEqual(m.record(wedged(30), tunnelRunning: true), .watching(consecutiveFailures: 2))
        XCTAssertEqual(m.record(wedged(60), tunnelRunning: true), .restart(attempt: 1))
        // Inside the settle window the edge has not had time to re-register.
        XCTAssertEqual(m.record(wedged(70), tunnelRunning: true), .suppressed(.settling))
        XCTAssertEqual(m.record(wedged(90), tunnelRunning: true), .suppressed(.settling))
        XCTAssertEqual(m.record(wedged(110), tunnelRunning: true), .suppressed(.settling))
    }

    func testBackoffGrowsAndCaps() {
        let m = TunnelLiveness(backoffBase: 60, backoffCap: 900)
        XCTAssertEqual(m.backoff(forAttempt: 1), 60)
        XCTAssertEqual(m.backoff(forAttempt: 2), 120)
        XCTAssertEqual(m.backoff(forAttempt: 3), 240)
        XCTAssertEqual(m.backoff(forAttempt: 4), 480)
        XCTAssertEqual(m.backoff(forAttempt: 5), 900, "capped")
        XCTAssertEqual(m.backoff(forAttempt: 9), 900)
    }

    // MARK: - Recovery

    /// The whole point: it fixes itself and goes quiet.
    func testRecoveryAfterARestartResetsEverything() {
        var m = TunnelLiveness()
        _ = run(&m, [wedged(0), wedged(30), wedged(60)])   // -> restart 1
        XCTAssertEqual(m.restartAttempt, 1)
        XCTAssertEqual(m.record(healthy(200), tunnelRunning: true), .healthy)
        XCTAssertEqual(m.restartAttempt, 0, "a good sample forgives the escalation")
        XCTAssertEqual(m.consecutiveFailures, 0)
        XCTAssertFalse(m.hasGivenUp)
    }

    /// Having given up must not be permanent — a later healthy run means the
    /// next fault is a fresh one.
    func testGivingUpIsForgivenByALaterHealthySample() {
        var m = TunnelLiveness(failuresBeforeRestart: 1, maxRestarts: 2, backoffBase: 1)
        var t = 0.0
        var sawGaveUp = false
        while t < 4000 {
            if case .gaveUp = m.record(wedged(t), tunnelRunning: true) { sawGaveUp = true }
            t += 30
        }
        XCTAssertTrue(sawGaveUp)
        XCTAssertEqual(m.record(healthy(t), tunnelRunning: true), .healthy)
        XCTAssertFalse(m.hasGivenUp)
        // And it can act again on a genuinely new fault.
        t += 30
        XCTAssertEqual(m.record(wedged(t), tunnelRunning: true), .restart(attempt: 1))
    }

    /// A stop mid-escalation clears the state, so coming back up starts clean.
    func testDeliberateStopClearsEscalation() {
        var m = TunnelLiveness()
        _ = run(&m, [wedged(0), wedged(30), wedged(60)])
        XCTAssertEqual(m.restartAttempt, 1)
        XCTAssertEqual(m.record(wedged(90), tunnelRunning: false), .suppressed(.tunnelNotRunning))
        XCTAssertEqual(m.restartAttempt, 0)
    }

    // MARK: - Status classification

    func testClassifiesTunnelFailuresVersusOriginFailures() {
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 200), .ok)
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 204), .ok)
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 302), .ok)
        // Cloudflare could not reach the tunnel.
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 530), .tunnelSuspect(status: 530))
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 502), .tunnelSuspect(status: 502))
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 503), .tunnelSuspect(status: 503))
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 504), .tunnelSuspect(status: 504))
        // Got through to us; our fault.
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 500), .originError(status: 500))
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 404), .originError(status: 404))
        XCTAssertEqual(TunnelLiveness.classify(publicStatus: 403), .originError(status: 403))
    }

    /// Cloudflare Access sits in front of another hostname on the same
    /// tunnel; a 403 from it must never read as a wedge.
    func testAnAccessRejectionIsNotAWedge() {
        var m = TunnelLiveness()
        let d = run(&m, (0..<6).map {
            TunnelLiveness.Sample(at: Double($0) * 30, localHealthy: true,
                                  publicOutcome: TunnelLiveness.classify(publicStatus: 403))
        })
        XCTAssertTrue(d.allSatisfy { $0 == .suppressed(.originFault) })
    }
}
