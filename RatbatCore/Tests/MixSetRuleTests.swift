import XCTest
@testable import RatbatCore

/// The classification rule is deliberately conservative about which title
/// markers fire on their own. The reason is measured, not aesthetic: of the
/// three generative sources, only Bandcamp supplies a duration at selection
/// time (`featured_track.duration`, present on 48/48 fixture items). NTS
/// carries a `duration` key that is `null` on all 21 rows of the shipped
/// tracklist fixture, and Last.fm has no duration field at all. So on two of
/// three sources the title arm is the *entire* classifier, with nothing to
/// corroborate it — which is exactly where a loose marker does the most
/// damage.
final class MixSetRuleTests: XCTestCase {

    // MARK: - Duration arm

    func testDurationAtThresholdIsAMixSet() {
        let verdict = MixSetRule.classify(title: "Untitled", durationSeconds: 1200)
        XCTAssertEqual(verdict, .duration(seconds: 1200))
    }

    func testDurationJustUnderThresholdIsNot() {
        XCTAssertNil(MixSetRule.classify(title: "Untitled", durationSeconds: 1199))
    }

    func testDurationArmWinsOverTitleArm() {
        // Both arms would fire; the duration arm is the authoritative one and
        // must be the reported reason, because it is the one the owner can
        // argue with numerically.
        let verdict = MixSetRule.classify(title: "DJ Set", durationSeconds: 3600)
        XCTAssertEqual(verdict, .duration(seconds: 3600))
    }

    func testNilDurationFallsThroughToTitleArm() {
        // The NTS / Last.fm case: no duration, ever.
        let verdict = MixSetRule.classify(title: "Boiler Room London", durationSeconds: nil)
        XCTAssertEqual(verdict, .title(marker: "Boiler Room"))
    }

    func testThresholdIsConfigurable() {
        let verdict = MixSetRule.classify(
            title: "Untitled", durationSeconds: 700, minimumDuration: 600
        )
        XCTAssertEqual(verdict, .duration(seconds: 700))
    }

    // MARK: - Title arm: markers that fire on their own

    func testUnambiguousMarkersFire() {
        let cases: [(String, String)] = [
            ("Boiler Room: Berlin", "Boiler Room"),
            ("Live at Berghain", "Live at"),
            ("The Ransom Note Podcast 44", "Podcast"),
            ("Episode 12", "Episode"),
            ("Ambient Works Part 2", "Part 2"),
            ("Dekmantel Podcast 301", "Podcast"),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(
                MixSetRule.classify(title: title, durationSeconds: nil),
                .title(marker: expected),
                "expected \(title) to classify via \(expected)"
            )
        }
    }

    func testQualifiedSetAndMixPhrasesFire() {
        let cases: [(String, String)] = [
            ("Objekt — DJ Set", "DJ Set"),
            ("Live Set at Dekmantel", "Live Set"),
            ("Full Set 2019", "Full Set"),
            ("Ben UFO b2b Pearson Sound", "b2b"),
            ("Continuous Mix", "Continuous Mix"),
            ("Mixed by Optimo", "Mixed by"),
            ("In the Mix", "In the Mix"),
            ("DJ Mix Vol. 4", "DJ Mix"),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(
                MixSetRule.classify(title: title, durationSeconds: nil),
                .title(marker: expected),
                "expected \(title) to classify via \(expected)"
            )
        }
    }

    // MARK: - Title arm: the false positives that matter

    /// The single most important test in this file. "(Original Mix)" and its
    /// siblings are the ubiquitous version suffix on exactly the two sources
    /// where the title arm is the only arm. A bare `mix` marker would drop a
    /// techno station's entire core repertoire — normal-length club tracks —
    /// with no duration to corroborate the call and nothing but an audit row
    /// to explain why the station went quiet.
    func testVersionSuffixMixIsNotAMixSet() {
        let survivors = [
            "Voodoo Ray (Original Mix)",
            "Strings of Life (Extended Mix)",
            "Windowlicker (Club Mix)",
            "Percolator (Dub Mix)",
            "Rej (Radio Mix)",
        ]
        for title in survivors {
            XCTAssertNil(
                MixSetRule.classify(title: title, durationSeconds: nil),
                "\(title) is a normal-length track, not a mix set"
            )
        }
    }

    func testBareSetAndMixWordsDoNotFire() {
        let survivors = [
            "Set It Off",
            "Sunset Boulevard",       // 'set' inside a word
            "Mixtape Vol. 3",         // 'mix' inside a word
            "Remix",                  // 'mix' inside a word
            "Remixes",
            "Sunset",
            "Settle",
            "Apartment 1",            // 'part' inside a word
            "Mixed Emotions",         // 'Mixed' without 'by'
        ]
        for title in survivors {
            XCTAssertNil(
                MixSetRule.classify(title: title, durationSeconds: nil),
                "\(title) must not classify as a mix set"
            )
        }
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(
            MixSetRule.classify(title: "boiler room: berlin", durationSeconds: nil),
            .title(marker: "boiler room")
        )
        XCTAssertEqual(
            MixSetRule.classify(title: "OBJEKT — DJ SET", durationSeconds: nil),
            .title(marker: "DJ SET")
        )
    }

    /// The marker reported is the literal text as it appeared in the title,
    /// not the canonical pattern — the audit row shows the owner what actually
    /// matched in their data, which is what makes "this threshold is wrong"
    /// an argument they can win.
    func testReportedMarkerIsTheLiteralMatchedText() {
        guard case .title(let marker)? = MixSetRule.classify(
            title: "Some Show — LIVE AT Fabric", durationSeconds: nil
        ) else {
            return XCTFail("expected a title verdict")
        }
        XCTAssertEqual(marker, "LIVE AT")
    }

    func testOrdinaryTrackIsNotAMixSet() {
        XCTAssertNil(MixSetRule.classify(title: "Xtal", durationSeconds: 292))
        XCTAssertNil(MixSetRule.classify(title: "Alberto Balsalm", durationSeconds: nil))
    }

    func testEmptyTitleIsNotAMixSet() {
        XCTAssertNil(MixSetRule.classify(title: "", durationSeconds: nil))
    }

    /// A 25-minute ambient record classifies on duration alone. This is the
    /// known, accepted false positive the owner called out in advance — the
    /// test exists so the behaviour is deliberate and visible, and so the
    /// audit row that records it is the thing that makes it recoverable.
    func testLongAmbientRecordClassifiesOnDurationAlone() {
        let verdict = MixSetRule.classify(title: "Substrata", durationSeconds: 1500)
        XCTAssertEqual(verdict, .duration(seconds: 1500))
    }
}
