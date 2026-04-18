# Taste Intelligence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add local taste intelligence to Last.fm-backed stations — a filter suite that drops mis-tagged candidates, a locally-derived taste profile that scores remaining candidates, and a dislike button that feeds negative signal back in. Stations surface music that is both surprising (new) and relevant (on-taste).

**Architecture:** Two-stage pool pipeline in `LastFMStationController.refillPool()` — hard filters narrow the raw pool, then `TasteProfile.score(candidate:stationID:)` sorts the survivors by affinity, with a 20% wildcard reservation to prevent convergence. Profile blends two layers: global signals derived passively from Jonas's 5022-track library (top artists, top tags) and per-station behavioral signals (♥-save, 👎-skip, play-through) from an extended `HistoryStore`. No Last.fm auth; everything lives locally.

**Tech Stack:** Swift 6 actors, SQLite via HistoryStore, SwiftUI for the dislike button + filter UI, Last.fm `artist.getTopTags` for precision mode verification, existing `TrackResolver` for YouTube resolution.

**Design doc:** `docs/plans/2026-04-18-taste-intelligence-design.md`

---

### Task 1: HistoryStore schema migration

Add columns `skipped`, `skipped_at`, `play_count` to the `history` table so the behavioral layer of the taste profile has a place to live. Schema must be idempotent (existing DBs on Jonas's Mac migrate in place without data loss).

**Files:**
- Modify: `RatbatCore/History/HistoryStore.swift` (init's `CREATE TABLE` block + new ALTERs)
- Test: `RatbatCore/Tests/HistoryStoreTests.swift`

**Step 1: Write failing test for the new columns**

Add test `test_markSkipped_recordsSkippedAt_` to `HistoryStoreTests.swift`:
```swift
func test_markSkipped_recordsSkipped() async throws {
    let store = try makeStore()
    let stationID = UUID()
    let rowid = try await store.record(
        station: stationID, artist: "A", title: "T",
        sourceShowURL: URL(string: "https://x")!,
        youtubeID: "y", cachedPath: "/tmp/x.m4a"
    )
    try await store.markSkipped(id: rowid)
    let skipped = try await store.skippedEntries(forStation: stationID)
    XCTAssertEqual(skipped.count, 1)
    XCTAssertEqual(skipped.first?.artist, "A")
}
```

**Step 2: Run test to verify it fails**

`xcodebuild test -scheme RatbatCore -only-testing:RatbatCoreTests/HistoryStoreTests/test_markSkipped_recordsSkipped`
Expected: FAIL — method `markSkipped` not defined.

**Step 3: Implement migration + markSkipped + skippedEntries**

In `HistoryStore.init()`, after the `CREATE TABLE` statement, run:
```swift
// Idempotent migrations — SQLite raises "duplicate column name" the
// second run; swallow that specific error so re-opens are no-ops.
for stmt in [
    "ALTER TABLE history ADD COLUMN skipped INTEGER NOT NULL DEFAULT 0;",
    "ALTER TABLE history ADD COLUMN skipped_at REAL;",
    "ALTER TABLE history ADD COLUMN play_count INTEGER NOT NULL DEFAULT 0;"
] {
    if sqlite3_exec(db, stmt, nil, nil, nil) != SQLITE_OK {
        let msg = String(cString: sqlite3_errmsg(db))
        if !msg.contains("duplicate column") { throw Error.schema(msg) }
    }
}
```

Add `markSkipped(id:)` and `skippedEntries(forStation:)` methods mirroring the existing `markSaved` / `savedEntries` shape.

**Step 4: Run test to verify it passes**

Same command. Expected: PASS.

**Step 5: Commit**
```bash
git add RatbatCore/History/HistoryStore.swift RatbatCore/Tests/HistoryStoreTests.swift
git commit -m "feat(history): add skipped / play_count columns + markSkipped API"
```

---

### Task 2: TasteProfile actor — library-derived signals

Build the passive, library-derived layer of `TasteProfile`. It ingests `[Track]` from the indexer and produces normalized signal dictionaries (top artists, top genre tags). Persisted to disk so app startup is instant.

**Files:**
- Create: `RatbatCore/Taste/TasteProfile.swift`
- Create: `RatbatCore/Taste/TasteProfileStore.swift`
- Test: `RatbatCore/Tests/TasteProfileTests.swift`

**Step 1: Write failing test**

```swift
func test_libraryProfile_ranksArtistsByTrackCount() async throws {
    let tracks = [
        Track(url: URL(fileURLWithPath: "/a"), title: "1", artist: "Miles", album: "", duration: 1),
        Track(url: URL(fileURLWithPath: "/b"), title: "2", artist: "Miles", album: "", duration: 1),
        Track(url: URL(fileURLWithPath: "/c"), title: "3", artist: "Monk", album: "", duration: 1)
    ]
    let profile = TasteProfile()
    await profile.ingestLibrary(tracks)
    let score = await profile.libraryArtistScore(for: "Miles")
    XCTAssertEqual(score, 1.0, accuracy: 0.01)    // max — 2 tracks
    let monk = await profile.libraryArtistScore(for: "Monk")
    XCTAssertEqual(monk, 0.5, accuracy: 0.01)     // 1 track / 2 max
}
```

**Step 2: Verify it fails**
Expected: `TasteProfile` type not defined.

**Step 3: Implement `TasteProfile` actor**

```swift
public actor TasteProfile {
    private var libraryArtists: [String: Double] = [:]
    private var libraryTags: [String: Double] = [:]

    public init() {}

    public func ingestLibrary(_ tracks: [Track]) {
        var counts: [String: Int] = [:]
        var tagCounts: [String: Int] = [:]
        for t in tracks {
            let artist = t.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty else { continue }
            counts[artist, default: 0] += 1
            if let genre = t.genre?.lowercased(), !genre.isEmpty {
                tagCounts[genre, default: 0] += 1
            }
        }
        let maxArtist = max(1, counts.values.max() ?? 1)
        libraryArtists = counts.mapValues { Double($0) / Double(maxArtist) }
        let maxTag = max(1, tagCounts.values.max() ?? 1)
        libraryTags = tagCounts.mapValues { Double($0) / Double(maxTag) }
    }

    public func libraryArtistScore(for artist: String) -> Double {
        libraryArtists[artist] ?? 0
    }
    public func libraryTagScore(for tag: String) -> Double {
        libraryTags[tag.lowercased()] ?? 0
    }
    public func libraryContainsArtist(_ artist: String) -> Bool {
        libraryArtists[artist] != nil
    }
}
```

Add a disk-cache companion `TasteProfileStore` with `save(_:to:)` / `load(from:)` JSON methods (pattern copied from `StationStore`).

**Step 4: Verify test passes**

**Step 5: Commit**
```bash
git add RatbatCore/Taste/ RatbatCore/Tests/TasteProfileTests.swift
git commit -m "feat(taste): add TasteProfile actor with library-derived signals"
```

---

### Task 3: TasteProfile behavioral signals

Extend `TasteProfile` to combine global library signals with per-station behavioral signals read from `HistoryStore`. Expose a single scoring entry point `score(candidate:stationID:)` returning `Double`.

**Files:**
- Modify: `RatbatCore/Taste/TasteProfile.swift`
- Modify: `RatbatCore/Tests/TasteProfileTests.swift`

**Step 1: Write failing test**

```swift
func test_score_blendsLibraryAndBehavioral() async throws {
    let profile = TasteProfile()
    await profile.ingestLibrary([
        Track(url: URL(fileURLWithPath: "/x"), title: "t", artist: "Miles", album: "", duration: 1)
    ])
    let history = try makeHistoryStore()
    let stationID = UUID()
    // Record a skipped entry
    let rowid = try await history.record(
        station: stationID, artist: "Kenny G", title: "Ugh",
        sourceShowURL: URL(string: "https://x")!,
        youtubeID: "y", cachedPath: "/tmp/x.m4a"
    )
    try await history.markSkipped(id: rowid)
    let libraryScore = await profile.score(
        candidateArtist: "Miles", candidateTags: [],
        stationID: stationID, history: history
    )
    let skippedScore = await profile.score(
        candidateArtist: "Kenny G", candidateTags: [],
        stationID: stationID, history: history
    )
    XCTAssertGreaterThan(libraryScore, 0.2)
    XCTAssertLessThan(skippedScore, 0)    // blacklisted
}
```

**Step 2: Verify fail**

**Step 3: Implement `score(candidateArtist:candidateTags:stationID:history:)`**

```swift
public func score(
    candidateArtist: String,
    candidateTags: [String],
    stationID: UUID,
    history: HistoryStore
) async -> Double {
    let libraryMatch: Double = libraryContainsArtist(candidateArtist) ? 1.0 : 0.0
    let tagMatch: Double = candidateTags
        .map { libraryTagScore(for: $0) }
        .reduce(0, +) / Double(max(1, candidateTags.count))
    let skipped = (try? await history.hasSkipped(
        station: stationID, artist: candidateArtist
    )) ?? false
    if skipped { return -1.0 }   // hard blacklist
    let savedAnywhere = (try? await history.savedEntries(forStation: stationID))
        .map { $0.contains(where: { $0.artist == candidateArtist }) } ?? false
    let saveAffinity: Double = savedAnywhere ? 1.0 : 0.0

    return 0.30 * libraryMatch
         + 0.25 * tagMatch
         + 0.35 * saveAffinity
}
```

Requires a new `HistoryStore.hasSkipped(station:artist:)` helper — add alongside `hasPlayed`.

**Step 4: Verify pass**

**Step 5: Commit**
```bash
git add RatbatCore/Taste/TasteProfile.swift RatbatCore/History/HistoryStore.swift RatbatCore/Tests/TasteProfileTests.swift
git commit -m "feat(taste): blend library + behavioral signals into a single score"
```

---

### Task 4: LastFMStationConfig filter fields

Add the filter fields (`TagMode`, `PopularityTier`, `PrecisionMode`, `excludeOwnedLibrary`, `excludedArtists`) to `LastFMStationConfig`. Keep `Codable` round-trip stable so existing stations migrate cleanly (defaults fill in for missing fields).

**Files:**
- Modify: `RatbatCore/Radio/LastFM/LastFMStationConfig.swift`
- Test: `RatbatCore/Tests/LastFMStationConfigTests.swift`

**Step 1: Write failing test for default values + codable round-trip**

```swift
func test_config_defaults_areConservative() {
    let cfg = LastFMStationConfig(name: "Test", tags: ["techno"])
    XCTAssertEqual(cfg.tagMode, .any)
    XCTAssertEqual(cfg.popularity, .middle)
    XCTAssertEqual(cfg.precision, .verified)
    XCTAssertFalse(cfg.excludeOwnedLibrary)
    XCTAssertTrue(cfg.excludedArtists.isEmpty)
}

func test_config_decodes_withoutNewFields() throws {
    // Old JSON shape without tagMode/popularity/precision/etc.
    let legacy = """
    {"id":"\(UUID())","name":"T","tags":["techno"],"shufflePool":true}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(LastFMStationConfig.self, from: legacy)
    XCTAssertEqual(decoded.tagMode, .any)
}
```

**Step 2: Verify fail**

**Step 3: Add the fields**

```swift
public enum TagMode: String, Codable, Sendable { case any, all }
public enum PopularityTier: String, Codable, Sendable { case hits, middle, deepCuts }
public enum PrecisionMode: String, Codable, Sendable { case off, verified, strict }

public struct LastFMStationConfig: Identifiable, Hashable, Sendable, Codable {
    // …existing fields…
    public var tagMode: TagMode = .any
    public var popularity: PopularityTier = .middle
    public var precision: PrecisionMode = .verified
    public var excludeOwnedLibrary: Bool = false
    public var excludedArtists: Set<String> = []
}
```

Defaults satisfy the legacy-decode test because Swift's auto-synthesized Codable treats missing fields as taking the struct's default value when using `@Decodable` with defaults (confirmed working when each stored property has an inline default).

**Step 4: Verify pass**

**Step 5: Commit**
```bash
git add RatbatCore/Radio/LastFM/LastFMStationConfig.swift RatbatCore/Tests/LastFMStationConfigTests.swift
git commit -m "feat(lastfm): add TagMode/Popularity/Precision filter fields to config"
```

---

### Task 5: LastFMClient.artistTopTags + artist-tag cache

Add an `artist.getTopTags` method + an in-actor cache keyed by normalized artist name. The controller will call this once per unique artist to verify precision.

**Files:**
- Modify: `RatbatCore/Radio/LastFM/LastFMClient.swift`
- Test: `RatbatCore/Tests/LastFMClientTests.swift`

**Step 1: Write failing test**

Use a fixture JSON `artistTopTags-portishead.json` with the known shape `{ toptags: { tag: [{ name, count }] } }` and assert `artistTopTags` returns the list sorted by count desc.

**Step 2: Verify fail**

**Step 3: Implement method**

```swift
public func artistTopTags(_ artist: String) async throws -> [ArtistTag] {
    let norm = artist.lowercased()
    if let cached = artistTagCache[norm] { return cached }
    var comps = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
    comps.queryItems = [
        URLQueryItem(name: "method", value: "artist.gettoptags"),
        URLQueryItem(name: "artist", value: artist),
        URLQueryItem(name: "autocorrect", value: "1"),
        URLQueryItem(name: "api_key", value: apiKey),
        URLQueryItem(name: "format", value: "json"),
    ]
    guard let url = comps.url else { return [] }
    let data = try await fetch(url)
    let tags = try parseArtistTags(from: data, sourceURL: url)
    artistTagCache[norm] = tags
    return tags
}
```

Plus DTOs, parser, and `ArtistTag { let name: String; let count: Int }` type.

**Step 4: Verify pass**

**Step 5: Commit**
```bash
git add RatbatCore/Radio/LastFM/LastFMClient.swift RatbatCore/Tests/LastFMClientTests.swift
git commit -m "feat(lastfm): add artist.getTopTags + per-artist cache"
```

---

### Task 6: LastFMStationController filter + score + wildcard pipeline

Replace the current `refillPool()` with the full pipeline: raw fetch → tag mode → popularity tier → library exclusion → artist blacklist → precision verification → taste scoring → wildcard reservation.

**Files:**
- Modify: `RatbatCore/Radio/LastFM/LastFMStationController.swift` (biggest change)
- Test: `RatbatCore/Tests/LastFMStationControllerTests.swift` (new integration test)

**Step 1: Write failing integration test**

Wire a fake `LastFMClient` (protocol-fronted for testability), a fake `TasteProfile`, a real `HistoryStore` against a temp SQLite, and assert:
- Candidate "Groove Coverage — Poison" is dropped when precision=verified and Groove Coverage's top tags don't include "techno".
- Candidate from an excluded artist is dropped.
- Candidate already skipped in history has score < 0 and is dropped.
- Final pool has ≤ 20% random (unscored) slots.

**Step 2: Verify fail**

**Step 3: Implement the pipeline**

Replace current `refillPool()` body; controller init now takes `TasteProfile` + `excludedArtists: Set<String>` derived from config. Pipeline filters applied in the order declared in the design doc. Scoring sorts, wildcard reservation splits.

**Step 4: Verify pass**

**Step 5: Commit**
```bash
git add RatbatCore/Radio/LastFM/LastFMStationController.swift RatbatCore/Tests/LastFMStationControllerTests.swift
git commit -m "feat(lastfm): taste-aware pool pipeline (filters + score + wildcards)"
```

---

### Task 7: Dislike (👎) button + RadioBroadcaster.skipCurrent

New endpoint on `RadioBroadcaster` that marks the current track as skipped in history and advances the encode loop. Wire up a 👎 button in both NTS and Last.fm detail views alongside the ♥ button, and in `PlayerView` when a live broadcast is running.

**Files:**
- Modify: `RatbatCore/Radio/RadioBroadcaster.swift` (`skipCurrent(stationID:)`)
- Modify: `RatbatCore/Views/NTSStationDetailView.swift`
- Modify: `RatbatCore/Views/LastFMStationDetailView.swift`
- Modify: `RatbatCore/Views/PlayerView.swift`
- Test: `RatbatCore/Tests/RadioBroadcasterTests.swift`

**Step 1: Write failing test for `skipCurrent(stationID:)`**

After starting a broadcast with a known track, call `skipCurrent(stationID:)` and assert:
- `history.hasSkipped(station:artist:)` returns true for that track.
- The pipeline's encode task has been told to advance (observable via the pipeline's `currentItemByStation` changing to a new item or nil within a bounded timeout).

**Step 2: Verify fail**

**Step 3: Implement**

```swift
public func skipCurrent(stationID: Station.ID) async {
    guard let item = currentItemByStation[stationID],
          let historyID = item.historyID else { return }
    do {
        try await history?.markSkipped(id: historyID)
    } catch {
        logger.error("skip mark failed: \(String(describing: error), privacy: .public)")
    }
    // Ask the encode loop to drop the current track. The pipeline
    // reads this flag at the top of each outer iteration. Simpler
    // than cancelling the decoder mid-track and lets the current
    // buffered chunk finish playing for any live listeners.
    pipelines[stationID]?.skipRequested = true
}
```

Add `skipRequested: Bool = false` to `BroadcastPipeline`. In `runEncodeLoop`'s inner loop, check `skipRequested` — if set, break the inner decode loop early and clear the flag.

Add 👎 button next to ♥ in both detail views; tapping calls `radio.skipCurrent(stationID:)`. Copy the disabled-state + per-URL tracking pattern used by the ♥ button.

**Step 4: Verify pass**

**Step 5: Commit**
```bash
git add RatbatCore/Radio/RadioBroadcaster.swift RatbatCore/Views/{NTS,LastFM}StationDetailView.swift RatbatCore/Views/PlayerView.swift RatbatCore/Tests/RadioBroadcasterTests.swift
git commit -m "feat(radio): skipCurrent API + 👎 button in detail views"
```

---

### Task 8: AddLastFMStationView filter UI

Expose `TagMode`, `PopularityTier`, `PrecisionMode`, `ExcludeOwnedLibrary` as controls inside a "Filters" DisclosureGroup in the station creation sheet. Excluded artists management deferred to Phase 2.

**Files:**
- Modify: `RatbatCore/Views/AddLastFMStationView.swift`

**Step 1: Sketch the UI in-view (no test — this is visual)**

Add after the existing tag picker:
```swift
DisclosureGroup("Filters") {
    Picker("Tag mode", selection: $tagMode) {
        Text("Any tag matches").tag(TagMode.any)
        Text("All tags must match").tag(TagMode.all)
    }
    Picker("Popularity", selection: $popularity) {
        Text("Hits (top 10%)").tag(PopularityTier.hits)
        Text("Middle (10-50%)").tag(PopularityTier.middle)
        Text("Deep cuts (bottom 50%)").tag(PopularityTier.deepCuts)
    }
    Picker("Precision", selection: $precision) {
        Text("Off — fast, noisy").tag(PrecisionMode.off)
        Text("Artist-verified").tag(PrecisionMode.verified)
        Text("Strict").tag(PrecisionMode.strict)
    }
    Toggle("Only surprise me — exclude my library", isOn: $excludeOwnedLibrary)
}
```

**Step 2: Wire the new fields into the config construction in `create()`.**

**Step 3: Rebuild + smoke-test by creating a new station with Strict + ExcludeLibrary and confirming the flags land in the saved JSON.**

**Step 4: Commit**
```bash
git add RatbatCore/Views/AddLastFMStationView.swift
git commit -m "feat(ui): filter suite in Last.fm station creation sheet"
```

---

### Task 9: Wire TasteProfile into RootView + library ingestion

Construct the shared `TasteProfile` in `RootView.init()`, hand it to `RadioBroadcaster` so the controllers can read it, and call `profile.ingestLibrary(tracks)` after `LibraryViewModel.load(from:)` finishes.

**Files:**
- Modify: `RatbatCore/Views/RootView.swift` (@StateObject or injected instance)
- Modify: `RatbatCore/Radio/RadioBroadcaster.swift` (pass-through to controllers)

**Step 1: Add `tasteProfile: TasteProfile` to the broadcaster's init and `makeLastFMSource` wiring.**

**Step 2: In `RootView`, construct a `TasteProfile` and hand it to the broadcaster.**

**Step 3: After library load, call `await tasteProfile.ingestLibrary(libraryVM.playlists.flatMap { $0.tracks })`.**

**Step 4: Run the app end-to-end — create a new Last.fm station with `precision=verified`, broadcast, confirm in the log that pool size drops by ~30-50% compared to a pre-taste baseline and that the first 20 tracks skew toward artists in Jonas's library.**

**Step 5: Commit**
```bash
git add RatbatCore/Views/RootView.swift RatbatCore/Radio/RadioBroadcaster.swift
git commit -m "feat(taste): wire TasteProfile into broadcaster + library ingest"
```

---

### Task 10: End-to-end smoke test

Not a unit test — a manual acceptance pass. Recreate the "techno" bug and confirm the fix:

1. Create a Last.fm station with tags `["techno"]`, precision `verified`, popularity `middle`.
2. Start broadcast.
3. Observe `log stream --predicate 'subsystem == "se.jonasjohansson.ratbat"' --level info` — confirm lines like `lastfm-station: precision dropped Groove Coverage (artist top tags: eurodance, pop, dance)`.
4. Listen for 20 minutes. Flag any off-genre play through.
5. Click 👎 on one offender. Restart broadcast. Confirm that track's artist is never picked again for this station.

**Commit** any tweaks from findings:
```bash
git commit -m "chore(taste): e2e tuning from acceptance run"
```

---

## Remember
- DRY, YAGNI, TDD, frequent commits
- Each task's test comes first, then minimal impl, then green, then commit
- SourceKit noise ("Cannot find type …") is cosmetic in this repo — only `xcodebuild` green matters
- Artist-tag cache is in-memory only for v1; losing it on restart is acceptable (warm takes ~10-20s)
- Profile is local-only, stored under `~/Library/Application Support/Ratbat/taste-profile.json`
- Referenced prior skills: @plugin:superpowers:test-driven-development

## Execution Handoff

Plan complete and saved to `docs/plans/2026-04-18-taste-intelligence.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open new session with executing-plans, batch execution with checkpoints

Which approach?
