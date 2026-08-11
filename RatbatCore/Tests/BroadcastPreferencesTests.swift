import XCTest
@testable import RatbatCore

/// Task 3.8 unit tests for the preferences store. We use the live
/// `UserDefaults.standard` because `@AppStorage` doesn't expose a custom
/// suite; each test calls ``BroadcastPreferences.resetToDefaults`` in
/// setUp/tearDown to keep cases isolated.
@MainActor
final class BroadcastPreferencesTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        BroadcastPreferences.shared.resetToDefaults()
    }

    override func tearDown() async throws {
        BroadcastPreferences.shared.resetToDefaults()
        try await super.tearDown()
    }

    func testDefaultsAreSensible() {
        let prefs = BroadcastPreferences()
        XCTAssertEqual(prefs.quality, .standard)
        XCTAssertEqual(prefs.sampleRate, .hz44100)
        XCTAssertEqual(prefs.port, 18000)
        XCTAssertTrue(prefs.icyMetadataEnabled)
    }

    func testBitrateForQualityReturnsExpected() {
        XCTAssertEqual(AudioQuality.voice.bitrate, 64_000)
        XCTAssertEqual(AudioQuality.standard.bitrate, 128_000)
        XCTAssertEqual(AudioQuality.high.bitrate, 192_000)
        XCTAssertEqual(AudioQuality.max.bitrate, 256_000)
    }

    func testAllAudioQualityCasesAreExposed() {
        // Guards against someone adding a case without updating the UI
        // picker's case coverage. Also confirms `allCases` sequencing.
        XCTAssertEqual(AudioQuality.allCases.count, 4)
        XCTAssertEqual(
            AudioQuality.allCases,
            [.voice, .standard, .high, .max]
        )
    }

    func testSampleRateRawValuesMatchHertz() {
        XCTAssertEqual(SampleRate.hz44100.rawValue, 44_100)
        XCTAssertEqual(SampleRate.hz48000.rawValue, 48_000)
    }

    func testPersistenceViaUserDefaults() {
        let first = BroadcastPreferences()
        first.quality = .high
        first.sampleRate = .hz48000
        first.port = 9000
        first.icyMetadataEnabled = false

        // A fresh instance reads from the same UserDefaults suite and
        // must see the values that `first` wrote.
        let second = BroadcastPreferences()
        XCTAssertEqual(second.quality, .high)
        XCTAssertEqual(second.sampleRate, .hz48000)
        XCTAssertEqual(second.port, 9000)
        XCTAssertFalse(second.icyMetadataEnabled)
    }

    func testRevisionTicksOnMutation() {
        let prefs = BroadcastPreferences()
        let start = prefs.revision
        prefs.quality = .voice
        XCTAssertGreaterThan(prefs.revision, start)

        let afterQuality = prefs.revision
        prefs.sampleRate = .hz48000
        XCTAssertGreaterThan(prefs.revision, afterQuality)
    }

    func testAudioQualityLabelsAreHumanReadable() {
        // Not a strict assertion — just makes sure nothing is empty, since
        // the picker displays these as-is.
        for q in AudioQuality.allCases {
            XCTAssertFalse(q.label.isEmpty)
        }
        for r in SampleRate.allCases {
            XCTAssertFalse(r.label.isEmpty)
        }
    }

    func testSelectionPolicyDefaults() {
        let p = BroadcastPreferences.shared.selectionPolicy
        XCTAssertEqual(p.newMusicShare, 0.7, accuracy: 0.0001)
        XCTAssertFalse(p.excludeMixSets)
    }

    func testSelectionPolicyRoundTrips() {
        let prefs = BroadcastPreferences.shared
        prefs.selectionPolicy = SelectionPolicy(newMusicShare: 0.25, excludeMixSets: true)
        XCTAssertEqual(prefs.selectionPolicy.newMusicShare, 0.25, accuracy: 0.0001)
        XCTAssertTrue(prefs.selectionPolicy.excludeMixSets)
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: "ratbat.selection.newMusicShare"),
            0.25, accuracy: 0.0001
        )
    }

    func testSelectionPolicyClampsOutOfRangeShare() {
        let prefs = BroadcastPreferences.shared
        prefs.selectionPolicy = SelectionPolicy(newMusicShare: 9)
        XCTAssertEqual(prefs.selectionPolicy.newMusicShare, 1.0, accuracy: 0.0001)
    }

    /// Both settings take effect at the next pool refill, so neither may raise
    /// the "needs restart" nag — a listener should not be interrupted to change
    /// how much new music they hear.
    func testSelectionPolicyDoesNotTickRevision() {
        let prefs = BroadcastPreferences.shared
        let before = prefs.revision
        prefs.selectionPolicy = SelectionPolicy(newMusicShare: 0.1, excludeMixSets: true)
        XCTAssertEqual(prefs.revision, before)
    }

    func testResetToDefaultsClearsSelectionPolicy() {
        let prefs = BroadcastPreferences.shared
        prefs.selectionPolicy = SelectionPolicy(newMusicShare: 0.1, excludeMixSets: true)
        prefs.resetToDefaults()
        XCTAssertEqual(prefs.selectionPolicy.newMusicShare, 0.7, accuracy: 0.0001)
        XCTAssertFalse(prefs.selectionPolicy.excludeMixSets)
    }

    func testAutoStartSlugsDefaultsEmpty() {
        XCTAssertEqual(BroadcastPreferences().autoStartSlugs, [])
    }

    func testAutoStartSlugsRoundTrip() {
        let first = BroadcastPreferences()
        first.autoStartSlugs = ["techno-90s", "dungeon-synth"]

        let second = BroadcastPreferences()
        XCTAssertEqual(second.autoStartSlugs, ["techno-90s", "dungeon-synth"])
        XCTAssertTrue(second.isAutoStart(slug: "techno-90s"))
        XCTAssertFalse(second.isAutoStart(slug: "ambient"))
    }

    func testSetAutoStartIsIdempotentBothDirections() {
        let prefs = BroadcastPreferences()
        prefs.setAutoStart(true, slug: "techno-90s")
        prefs.setAutoStart(true, slug: "techno-90s")
        XCTAssertEqual(prefs.autoStartSlugs, ["techno-90s"], "double-enable must not duplicate")

        prefs.setAutoStart(false, slug: "techno-90s")
        prefs.setAutoStart(false, slug: "techno-90s")
        XCTAssertEqual(prefs.autoStartSlugs, [], "double-disable must be a no-op")
    }

    func testSetAutoStartPreservesOrder() {
        let prefs = BroadcastPreferences()
        prefs.setAutoStart(true, slug: "a")
        prefs.setAutoStart(true, slug: "b")
        prefs.setAutoStart(true, slug: "c")
        prefs.setAutoStart(false, slug: "b")
        XCTAssertEqual(prefs.autoStartSlugs, ["a", "c"])
    }

    /// Auto-start has no effect on a running pipeline, so toggling it must
    /// NOT tick `revision` — otherwise flipping a toggle mid-broadcast
    /// raises a spurious "restart to apply" banner.
    func testAutoStartDoesNotTickRevision() {
        let prefs = BroadcastPreferences()
        let start = prefs.revision
        prefs.setAutoStart(true, slug: "techno-90s")
        prefs.setAutoStart(false, slug: "techno-90s")
        XCTAssertEqual(prefs.revision, start)
    }

    func testResetToDefaultsClearsAutoStart() {
        let prefs = BroadcastPreferences()
        prefs.setAutoStart(true, slug: "techno-90s")
        prefs.resetToDefaults()
        // `@AppStorage` wrappers cache per-instance — reset clears the
        // backing defaults, so read through a fresh instance (same
        // pattern as `testPersistenceViaUserDefaults`).
        XCTAssertEqual(BroadcastPreferences().autoStartSlugs, [])
    }

    /// Changing preferences while at least one station is live must flip
    /// `needsRestart` on the broadcaster so the UI can surface a banner.
    func testBroadcasterFlagsNeedsRestartOnPreferenceChange() async throws {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()

        let radio = RadioBroadcaster(preferences: prefs)
        XCTAssertFalse(radio.needsRestart)

        // No live station — changing prefs must NOT flag restart, because
        // a fresh start will pick up the new values naturally.
        prefs.quality = .high
        // Give Combine a tick to deliver.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(
            radio.needsRestart,
            "needsRestart should stay false when no stations are live"
        )
    }

    // MARK: - Owner passcode

    /// The owner key is settable so it can be a passcode a human can
    /// remember, not just the UUID generated on first use.
    func testOwnerTokenIsSettable() {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        let generated = prefs.ownerToken
        XCTAssertFalse(generated.isEmpty)

        prefs.ownerToken = "a-chosen-passcode"
        XCTAssertEqual(prefs.ownerToken, "a-chosen-passcode")
        XCTAssertNotEqual(prefs.ownerToken, generated)
        XCTAssertTrue(prefs.isOwner(token: "a-chosen-passcode"))
        XCTAssertFalse(prefs.isOwner(token: generated))
    }

    /// Surrounding whitespace is stripped on the way in. A passcode pasted
    /// out of a note drags a newline along and would otherwise be stored
    /// as a key nobody can type.
    func testOwnerTokenTrimsWhitespaceWhenStored() {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "  spaced-passcode\n"
        XCTAssertEqual(prefs.ownerToken, "spaced-passcode")
    }

    /// Blanking the passcode means "issue a new random one", never "no key
    /// at all" — an empty key would reject every request and read as the
    /// owner buttons being broken.
    func testBlankingOwnerTokenIssuesAFreshRandomKey() {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "temporary"
        prefs.ownerToken = "   "
        XCTAssertFalse(prefs.ownerToken.isEmpty)
        XCTAssertNotEqual(prefs.ownerToken, "temporary")
        XCTAssertFalse(prefs.isOwner(token: ""))
        XCTAssertFalse(prefs.isOwner(token: nil))
    }

    /// The passcode is typed by hand now, so the comparison tolerates the
    /// two things human typing reliably adds: a capital first letter from
    /// a phone keyboard, and stray surrounding whitespace.
    func testIsOwnerToleratesCaseAndWhitespaceOnTheWire() {
        let prefs = BroadcastPreferences()
        prefs.resetToDefaults()
        prefs.ownerToken = "correct-horse"

        XCTAssertTrue(prefs.isOwner(token: "correct-horse"))
        XCTAssertTrue(prefs.isOwner(token: "Correct-Horse"))
        XCTAssertTrue(prefs.isOwner(token: "CORRECT-HORSE"))
        XCTAssertTrue(prefs.isOwner(token: "  correct-horse  "))
        XCTAssertTrue(prefs.isOwner(token: "\tcorrect-horse\n"))

        XCTAssertFalse(prefs.isOwner(token: "correct-horse-battery"))
        XCTAssertFalse(prefs.isOwner(token: "correcthorse"))
        XCTAssertFalse(prefs.isOwner(token: "wrong"))
    }
}
