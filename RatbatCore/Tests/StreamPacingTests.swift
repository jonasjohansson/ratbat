import XCTest
@testable import RatbatCore

/// The encode loop feeds every listener. If it writes faster than the
/// audio plays, nobody notices at first — the browser just buffers — and
/// then the stream is a minute behind `/now.json` and drifting, so the
/// title on the page changes at a different moment than the sound in the
/// room. That was the bug: a flat 70ms sleep per ~93ms chunk, described
/// in the source as staying "~1 chunk ahead", is really a 1.2–1.3x
/// overfeed that compounds for as long as anyone listens. Measured
/// against the live station it shipped 37.1s of audio every 30.1s of
/// wall clock.
///
/// These cover the arithmetic that replaced it.
final class StreamPacingTests: XCTestCase {

    private let lead = RadioBroadcaster.broadcastLeadSeconds

    /// Inside the lead there is nothing to wait for — that runway is the
    /// point, it is what a listener's buffer holds against a stalled read.
    func testWritesFreelyUntilTheLeadIsFull() {
        let now = 1_000.0
        var head = now
        var slept = 0.0
        // Half a lead's worth of audio, an eighth of a second at a time.
        for _ in 0..<20 {
            let paced = RadioBroadcaster.pace(
                playoutHead: head, now: now, chunkSeconds: 0.125, lead: lead
            )
            head = paced.head
            slept += paced.sleep
        }
        XCTAssertEqual(head, now + 2.5, accuracy: 0.0001)
        XCTAssertEqual(slept, 0, "2.5s of audio fits inside a \(lead)s lead")
    }

    /// The property the old code broke: over any stretch of wall clock,
    /// the encoder emits that much audio and no more. Simulated with a
    /// clock that only advances when the pacer says to wait, so any
    /// systematic overfeed shows up as audio outrunning the clock.
    func testFeedsRealTimeOverTheLongRun() {
        let start = 5_000.0
        var now = start
        var head = now
        var audioWritten = 0.0
        let chunk = 4_096.0 / 44_100.0   // one decoder read at 44.1 kHz

        // ~10 minutes of radio.
        for _ in 0..<6_500 {
            let paced = RadioBroadcaster.pace(
                playoutHead: head, now: now, chunkSeconds: chunk, lead: lead
            )
            head = paced.head
            audioWritten += chunk
            now += paced.sleep
        }

        let elapsed = now - start
        let ratio = audioWritten / elapsed
        // The lead is written up front and never repaid, so audio leads
        // wall clock by exactly that much — a constant, not a slope.
        XCTAssertEqual(audioWritten - elapsed, lead, accuracy: chunk)
        XCTAssertLessThan(ratio, 1.02, "no drift: ratio was \(ratio)")
        XCTAssertGreaterThan(ratio, 0.98, "and no starving: ratio was \(ratio)")
    }

    /// A station with nobody listening parks at the track boundary, and a
    /// slow source can stall mid-track. Either way the playout head is
    /// left far in the past, and the encoder must NOT then sprint to
    /// repay minutes of audio — that burst is what desyncs the listener.
    func testReAnchorsAfterAStallInsteadOfSprinting() {
        let head = 1_000.0
        // Ten minutes parked on the listener gate.
        let paced = RadioBroadcaster.pace(
            playoutHead: head, now: head + 600, chunkSeconds: 0.1, lead: lead
        )
        XCTAssertEqual(paced.head, head + 600, "head re-anchored to now")
        XCTAssertEqual(paced.sleep, 0, "and no debt to sleep off")

        // The very next chunk paces normally from the new anchor rather
        // than carrying anything over.
        let next = RadioBroadcaster.pace(
            playoutHead: paced.head, now: head + 600, chunkSeconds: 0.1, lead: lead
        )
        XCTAssertEqual(next.head, head + 600.1, accuracy: 0.0001)
        XCTAssertEqual(next.sleep, 0)
    }

    /// Once the lead is full, one chunk in buys one chunk of waiting —
    /// the encoder tracks the clock rather than pulling away from it.
    func testAtSteadyStateAChunkCostsItsOwnDuration() {
        let now = 2_000.0
        let paced = RadioBroadcaster.pace(
            playoutHead: now + lead, now: now, chunkSeconds: 0.093, lead: lead
        )
        XCTAssertEqual(paced.sleep, 0.093, accuracy: 0.0001)
    }

    /// Never a negative sleep, whatever the inputs — `Task.sleep` takes
    /// an unsigned count of nanoseconds, so a negative here would wrap
    /// into a wait of several hundred years.
    func testSleepIsNeverNegative() {
        for offset in stride(from: -10.0, through: 10.0, by: 0.5) {
            let paced = RadioBroadcaster.pace(
                playoutHead: 100 + offset, now: 100, chunkSeconds: 0.1, lead: lead
            )
            XCTAssertGreaterThanOrEqual(paced.sleep, 0, "offset \(offset)")
        }
    }

    /// The lead rides `/now.json` so the web client can subtract it when
    /// deciding *when* to show a track change. A lead the client cannot
    /// see is a lead it has to guess at, which is where the flat 10s
    /// guess in the browser came from.
    func testLeadIsAUsableNumber() {
        XCTAssertGreaterThan(RadioBroadcaster.broadcastLeadSeconds, 0)
        XCTAssertLessThanOrEqual(
            RadioBroadcaster.broadcastLeadSeconds, 30,
            "the client clamps at 30s; a larger lead would arrive silently truncated"
        )
    }

    // MARK: - The ring has to be able to hold the lead

    /// `pace()` deliberately writes up to `broadcastLeadSeconds` past the
    /// playout head, and that audio sits in the ring until a listener
    /// drains it. A ring smaller than the lead therefore laps every reader
    /// at steady state — not merely after a stalled read.
    ///
    /// The old fixed 128KB was exactly that: 8.2s at 128 kbps but 4.1s at
    /// the 256 kbps the station actually broadcasts, i.e. under the 5s
    /// lead. Sizing in bytes hid it, because the number only looked wrong
    /// once you divided by a bitrate.
    func testRingHoldsTheEncoderLeadAtEveryQuality() {
        let lead = RadioBroadcaster.broadcastLeadSeconds
        for quality in AudioQuality.allCases {
            let bytes = AACRingBuffer.capacity(
                bitrate: quality.bitrate, seconds: lead * 2
            )
            let seconds = Double(bytes) / (Double(quality.bitrate) / 8)
            XCTAssertGreaterThan(
                seconds, lead,
                "\(quality.rawValue) (\(quality.bitrate) bps): ring holds \(seconds)s, under the \(lead)s lead"
            )
        }
    }

    /// Pins the specific regression, so the old constant cannot come back
    /// without someone reading why it went.
    func testFixedByteRingWasUnderTheLeadAtMaxQuality() {
        let lead = RadioBroadcaster.broadcastLeadSeconds
        let legacySeconds = Double(128 * 1024) / (256_000.0 / 8)
        XCTAssertEqual(legacySeconds, 4.096, accuracy: 0.001)
        XCTAssertLessThan(legacySeconds, lead, "this is the bug: ring smaller than the lead")

        let fixed = AACRingBuffer.capacity(bitrate: 256_000, seconds: lead * 2)
        XCTAssertGreaterThan(Double(fixed) / (256_000.0 / 8), lead)
    }
}
