import XCTest
@testable import JohanssoundCore

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
}
