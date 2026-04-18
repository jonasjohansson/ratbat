# Faceted Stations + Bandcamp + MusicBrainz — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the flat-tag generative-station model with faceted queries (genre × era × region), add Bandcamp as a third source, and introduce MusicBrainz as an enrichment layer. Fix the "Exaltasamba-in-Techno" class of mis-tagging bug as a side effect.

**Architecture:** One shared `FacetedQuery` struct consumed by both the upgraded `LastFMStationConfig` and the new `BandcampStationConfig`. Post-filter pipeline stages extracted into a `FacetedPipeline` namespace shared between `LastFMStationController` and new `BandcampStationController`. MusicBrainz is the authoritative source for era (`first-release-date`) and region (`artist.area.iso-3166-1-codes`). `TrackResolver` gains a direct-URL shortcut so Bandcamp candidates bypass YouTube-Music matching and hand their release URL straight to yt-dlp.

**Tech Stack:** Swift / SwiftUI (macOS), XCTest, Xcode 16.x via `xcodegen` and `install.sh`, existing yt-dlp + Python resolver subprocess, SQLite history store, JSON file persistence via `StationStore`.

**Design doc:** `docs/plans/2026-04-18-faceted-stations-bandcamp-musicbrainz-design.md` — read this first if you haven't.

---

## Engineer prep

Before starting, read these files to get oriented:
- `RatbatCore/Radio/Station.swift` — the `Station.Kind` enum is where the new case lands
- `RatbatCore/Radio/LastFM/LastFMStationConfig.swift` — the migration-via-`decodeIfPresent` pattern is here; copy it
- `RatbatCore/Radio/LastFM/LastFMStationController.swift` — the pipeline stages we're extracting
- `RatbatCore/Radio/LastFM/LastFMClient.swift` — shape of a Client actor
- `RatbatCore/Tests/LastFMStationConfigTests.swift` — the migration-assurance test pattern

**Test runner.** Tests live under `RatbatCore/Tests/` and are platform-gated `#if os(macOS)`. Run the whole suite from the repo root with:

```bash
xcodebuild test -project Ratbat.xcodeproj -scheme Ratbat -destination 'platform=macOS' 2>&1 | tail -40
```

or (faster during tight iteration) Test navigator in Xcode. Re-run after every task.

**Commit style.** Match the repo's recent history — `feat:` / `fix:` / `test:` / `chore:` conventional-commit prefix, imperative-mood subject, brief body. Look at `git log --oneline -20` for examples.

**Worktree (optional but recommended).** This is a multi-day change. Create a dedicated branch/worktree:
```bash
git worktree add ../ratbat-faceted -b feat/faceted-stations
cd ../ratbat-faceted
```
…and work from there. Skip if you prefer to work on `main`.

---

## Phase A — Data model

### Task 1: Add `FacetedQuery` struct and enums

**Files:**
- Create: `RatbatCore/Radio/FacetedQuery.swift`
- Create: `RatbatCore/Tests/FacetedQueryTests.swift`

**Step 1: Write the failing test**

```swift
#if os(macOS)
import XCTest
@testable import RatbatCore

final class FacetedQueryTests: XCTestCase {

    func testDefaults_areSensible() {
        let q = FacetedQuery(genreTags: ["techno"])
        XCTAssertEqual(q.tagMatch, .any)
        XCTAssertEqual(q.popularity, .middle)
        XCTAssertNil(q.yearMin)
        XCTAssertNil(q.yearMax)
        XCTAssertTrue(q.regions.isEmpty)
        XCTAssertFalse(q.excludeOwnedLibrary)
        XCTAssertTrue(q.excludedArtists.isEmpty)
    }

    func testRoundTrip_preservesAllFields() throws {
        var q = FacetedQuery(genreTags: ["techno", "house"])
        q.yearMin = 1990
        q.yearMax = 1999
        q.regions = ["JP", "DE"]
        q.tagMatch = .all
        q.popularity = .deepCuts
        q.excludeOwnedLibrary = true
        q.excludedArtists = ["Excluded Artist"]
        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(FacetedQuery.self, from: data)
        XCTAssertEqual(decoded, q)
    }
}
#endif
```

**Step 2: Run test to verify it fails**

Run the tests. Expected: compiler error, `FacetedQuery` doesn't exist.

**Step 3: Write the implementation**

```swift
import Foundation

/// Faceted query over candidate tracks. Consumed by both
/// ``LastFMStationConfig`` and ``BandcampStationConfig``; the per-source
/// controllers translate each facet into the appropriate filter stage.
///
/// Facet semantics:
/// - `genreTags`: OR within the array (subject to ``tagMatch``); required (>= 1).
/// - `yearMin` / `yearMax`: closed year range, AND against other facets.
/// - `regions`: OR within the array, AND across facets. ISO 3166 alpha-2 codes ("JP", "DE").
/// - `tagMatch`: any | all. Applies to `genreTags` only — era and region
///   are always AND'd regardless.
public struct FacetedQuery: Hashable, Sendable, Codable {
    public var genreTags: [String]
    public var yearMin: Int?
    public var yearMax: Int?
    public var regions: [String]
    public var tagMatch: TagMatch
    public var popularity: PopularityTier
    public var excludeOwnedLibrary: Bool
    public var excludedArtists: Set<String>

    public init(
        genreTags: [String],
        yearMin: Int? = nil,
        yearMax: Int? = nil,
        regions: [String] = [],
        tagMatch: TagMatch = .any,
        popularity: PopularityTier = .middle,
        excludeOwnedLibrary: Bool = false,
        excludedArtists: Set<String> = []
    ) {
        self.genreTags = genreTags
        self.yearMin = yearMin
        self.yearMax = yearMax
        self.regions = regions
        self.tagMatch = tagMatch
        self.popularity = popularity
        self.excludeOwnedLibrary = excludeOwnedLibrary
        self.excludedArtists = excludedArtists
    }
}

/// Intra-facet combination strategy for `genreTags`.
public enum TagMatch: String, Hashable, Codable, Sendable {
    case any  // OR — default; broadest pool
    case all  // AND — narrower, used to intersect tags like "techno" + "ambient"
}

/// Popularity-tier partitioning. Last.fm-only signal; ignored by the
/// Bandcamp controller (Bandcamp has no listener count).
public enum PopularityTier: String, Hashable, Codable, Sendable {
    case hits       // top 10% by listener count
    case middle     // 10-50th percentile — default, balanced
    case deepCuts   // bottom 50% — underground / discovery
}
```

**Step 4: Run tests to verify they pass**

Expected: both tests pass.

**Step 5: Commit**

```bash
git add RatbatCore/Radio/FacetedQuery.swift RatbatCore/Tests/FacetedQueryTests.swift
git commit -m "feat: add FacetedQuery — shared faceted query struct for generative stations"
```

---

### Task 2: Migrate `LastFMStationConfig` to use `FacetedQuery`

**Files:**
- Modify: `RatbatCore/Radio/LastFM/LastFMStationConfig.swift` (full rewrite)
- Modify: `RatbatCore/Tests/LastFMStationConfigTests.swift` (add migration test)
- Delete: `LastFMTagMode`, `LastFMPopularityTier`, `LastFMPrecisionMode` enums (moved/folded into `FacetedQuery`)

**Step 1: Write the migration-assurance test**

Append to `LastFMStationConfigTests.swift`:

```swift
func testDecode_preFacetedShape_hydratesFacetedQuery() throws {
    // Shape as stored on disk before the faceted redesign. Every pre-
    // facet field is present; the decoder must promote them into the new
    // FacetedQuery-carrying shape without user action.
    let legacy = """
    {
      "id": "\(UUID().uuidString)",
      "name": "Legacy",
      "tags": ["techno", "house"],
      "yearMin": 1990,
      "yearMax": 1999,
      "shufflePool": true,
      "tagMode": "all",
      "popularity": "deepCuts",
      "precision": "verified",
      "excludeOwnedLibrary": true,
      "excludedArtists": ["Scooter"]
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(LastFMStationConfig.self, from: legacy)
    XCTAssertEqual(decoded.query.genreTags, ["techno", "house"])
    XCTAssertEqual(decoded.query.yearMin, 1990)
    XCTAssertEqual(decoded.query.yearMax, 1999)
    XCTAssertEqual(decoded.query.tagMatch, .all)
    XCTAssertEqual(decoded.query.popularity, .deepCuts)
    XCTAssertTrue(decoded.query.excludeOwnedLibrary)
    XCTAssertEqual(decoded.query.excludedArtists, ["Scooter"])
}

func testEncode_writesNewShapeOnly() throws {
    var cfg = LastFMStationConfig(name: "T", query: FacetedQuery(genreTags: ["techno"]))
    cfg.query.yearMin = 1990
    let data = try JSONEncoder().encode(cfg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertNotNil(json["query"], "new shape should include a query field")
    XCTAssertNil(json["tags"], "legacy 'tags' key should not be written")
    XCTAssertNil(json["yearMin"], "legacy top-level 'yearMin' should not be written")
}
```

**Also update the existing tests:** rename `LastFMStationConfig(name:tags:)` calls to use `LastFMStationConfig(name:query:)` with a `FacetedQuery`. The `testDefaults_areConservative` and `testRoundTrip_preservesAllFields` tests need their call sites updated — the enum defaults live on `FacetedQuery` now, not `LastFMStationConfig`.

**Step 2: Run tests to verify they fail**

Expected: compile errors — `LastFMStationConfig.query` doesn't exist.

**Step 3: Rewrite `LastFMStationConfig.swift`**

```swift
import Foundation

/// Blueprint for a generative Last.fm-backed station. The facet shape is
/// delegated entirely to ``FacetedQuery``; this struct just holds the
/// identity + one Last.fm-specific lifecycle flag.
///
/// Migration: older on-disk configs predating the faceted redesign
/// encoded facet fields at the top level (`tags`, `yearMin`, `yearMax`,
/// `tagMode`, `popularity`, `excludeOwnedLibrary`, `excludedArtists`).
/// The custom `init(from:)` below detects those and hydrates a
/// ``FacetedQuery`` on the fly — no ``StationStore`` version bump needed.
public struct LastFMStationConfig: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var query: FacetedQuery
    public var shufflePool: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        query: FacetedQuery,
        shufflePool: Bool = true
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.shufflePool = shufflePool
    }

    // MARK: - Codable with legacy-shape migration

    private enum CodingKeys: String, CodingKey {
        // New shape
        case id, name, query, shufflePool
        // Legacy keys (decode-only, never written)
        case tags
        case yearMin, yearMax
        case tagMode, popularity, excludeOwnedLibrary, excludedArtists
        // `precision` was also a legacy field — dropped entirely, handled
        // implicitly inside LastFMStationController now.
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.shufflePool = try c.decodeIfPresent(Bool.self, forKey: .shufflePool) ?? true

        if let q = try c.decodeIfPresent(FacetedQuery.self, forKey: .query) {
            self.query = q
        } else {
            // Legacy shape — hydrate a FacetedQuery from the flat fields.
            let tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            let yearMin = try c.decodeIfPresent(Int.self, forKey: .yearMin)
            let yearMax = try c.decodeIfPresent(Int.self, forKey: .yearMax)
            let tagMode = try c.decodeIfPresent(String.self, forKey: .tagMode) ?? "any"
            let popularity = try c.decodeIfPresent(String.self, forKey: .popularity) ?? "middle"
            let excludeOwnedLibrary = try c.decodeIfPresent(Bool.self, forKey: .excludeOwnedLibrary) ?? false
            let excludedArtists = try c.decodeIfPresent(Set<String>.self, forKey: .excludedArtists) ?? []

            self.query = FacetedQuery(
                genreTags: tags,
                yearMin: yearMin,
                yearMax: yearMax,
                regions: [],
                tagMatch: TagMatch(rawValue: tagMode) ?? .any,
                popularity: PopularityTier(rawValue: popularity) ?? .middle,
                excludeOwnedLibrary: excludeOwnedLibrary,
                excludedArtists: excludedArtists
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(query, forKey: .query)
        try c.encode(shufflePool, forKey: .shufflePool)
    }
}
```

Delete the old `LastFMTagMode`, `LastFMPopularityTier`, `LastFMPrecisionMode` enums from this file. Precision is gone; the other two are replaced by `TagMatch` / `PopularityTier` on `FacetedQuery`.

**Step 4: Fix call-site fallout**

Expected compile errors after the rewrite, in rough order:
- `AddLastFMStationView.swift` references `LastFMTagMode`, `LastFMPopularityTier`, `LastFMPrecisionMode`, and builds a `LastFMStationConfig(name:tags:...)` with the old API.
- `StationManager.swift` `createLastFM` builder may reference old fields.
- `LastFMStationController.swift` reads `config.tags`, `config.tagMode`, etc. directly — these all become `config.query.genreTags`, `config.query.tagMatch`, etc.

**Only fix the compile errors mechanically — do NOT reshape the UI or controller yet.** That's Tasks 11 and 20. Stub any UI code whose structure will change; e.g. `AddLastFMStationView` can hard-code `precision` references removed and keep the rest intact by accessing through `config.query.*` temporarily.

**Step 5: Run tests**

Expected: new migration tests pass, existing tests pass (after call-site updates), project compiles.

**Step 6: Commit**

```bash
git add RatbatCore/Radio/LastFM/LastFMStationConfig.swift \
        RatbatCore/Tests/LastFMStationConfigTests.swift \
        RatbatCore/Views/AddLastFMStationView.swift \
        RatbatCore/Radio/LastFM/LastFMStationController.swift \
        RatbatCore/Radio/StationManager.swift
git commit -m "feat: migrate LastFMStationConfig to FacetedQuery shape with backward-compat decode"
```

---

## Phase B — MusicBrainz client

### Task 3: `MusicBrainzClient` skeleton + parse tests

**Files:**
- Create: `RatbatCore/Radio/MusicBrainz/MusicBrainzClient.swift`
- Create: `RatbatCore/Tests/MusicBrainzClientTests.swift`
- Create: `RatbatCore/Tests/Fixtures/musicbrainz-recording-search.json`
- Create: `RatbatCore/Tests/Fixtures/musicbrainz-artist-search.json`

**Step 1: Save fixture JSON**

Record a real-world response shape. `musicbrainz-recording-search.json`:

```json
{
  "created": "2026-04-18T00:00:00.000Z",
  "count": 1,
  "offset": 0,
  "recordings": [
    {
      "id": "abc-123",
      "score": 100,
      "title": "Quero Sentir De Novo",
      "first-release-date": "2003-05-14",
      "artist-credit": [
        { "artist": { "id": "artist-xyz", "name": "Exaltasamba" } }
      ]
    }
  ]
}
```

`musicbrainz-artist-search.json`:

```json
{
  "created": "2026-04-18T00:00:00.000Z",
  "count": 1,
  "artists": [
    {
      "id": "artist-xyz",
      "score": 100,
      "name": "Exaltasamba",
      "country": "BR",
      "area": {
        "id": "area-br",
        "name": "Brazil",
        "iso-3166-1-codes": ["BR"]
      }
    }
  ]
}
```

**Step 2: Write the parse tests**

```swift
#if os(macOS)
import XCTest
@testable import RatbatCore

final class MusicBrainzClientTests: XCTestCase {

    func testParseRecordingSearch_extractsFirstReleaseYear() throws {
        let data = try fixtureData("musicbrainz-recording-search")
        let year = MusicBrainzClient.parseFirstReleaseYear(from: data)
        XCTAssertEqual(year, 2003)
    }

    func testParseArtistSearch_extractsISOCountryCode() throws {
        let data = try fixtureData("musicbrainz-artist-search")
        let code = MusicBrainzClient.parseCountryCode(from: data)
        XCTAssertEqual(code, "BR")
    }

    func testParseRecordingSearch_emptyResults_returnsNil() {
        let empty = Data("""
        { "created": "2026-04-18T00:00:00.000Z", "count": 0, "recordings": [] }
        """.utf8)
        XCTAssertNil(MusicBrainzClient.parseFirstReleaseYear(from: empty))
    }

    func testParseArtistSearch_noArea_returnsNil() {
        let noArea = Data("""
        { "count": 1, "artists": [{ "id": "x", "name": "X" }] }
        """.utf8)
        XCTAssertNil(MusicBrainzClient.parseCountryCode(from: noArea))
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("Fixture \(name).json not found in test bundle")
        }
        return try Data(contentsOf: url)
    }
}
#endif
```

**Step 3: Implement the parse functions + skeleton actor**

```swift
import Foundation
import OSLog

/// MusicBrainz wrapper — supplies authoritative year + region metadata
/// for candidates surfaced by other sources (Last.fm, Bandcamp).
///
/// Two public lookup methods, both returning `Optional` so the caller
/// can fail-open when MB doesn't know (common for Bandcamp bedroom-
/// producer tracks). Actor-serialized and rate-limited to 1.05s between
/// outbound requests — MB's public server caps at 1 req/sec and throttles
/// hard on the User-Agent if missing.
public actor MusicBrainzClient {

    public enum Error: Swift.Error, Sendable {
        case badResponse(URL)
    }

    private let userAgent: String
    private let session: URLSession
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "musicbrainz")
    private static let apiBase = URL(string: "https://musicbrainz.org/ws/2/")!

    private var recordingCache: [String: Int?] = [:]
    private var artistCache: [String: String?] = [:]
    private var lastRequestAt: Date?

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    // MARK: - Public

    public func firstReleaseYear(artist: String, title: String) async -> Int? {
        let key = "\(artist.lowercased())\u{1}\(title.lowercased())"
        if let hit = recordingCache[key] { return hit }

        let query = "artist:\"\(escape(artist))\" AND recording:\"\(escape(title))\""
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent("recording"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = comps.url else {
            recordingCache[key] = .some(nil)
            return nil
        }

        do {
            let data = try await throttledFetch(url)
            let year = Self.parseFirstReleaseYear(from: data)
            recordingCache[key] = .some(year)
            return year
        } catch {
            logger.info("firstReleaseYear failed for \(artist, privacy: .public) — \(title, privacy: .public): \(String(describing: error), privacy: .public)")
            // Don't cache failures — transient issues deserve a retry
            // next refill.
            return nil
        }
    }

    public func countryCode(forArtist artist: String) async -> String? {
        let key = artist.lowercased()
        if let hit = artistCache[key] { return hit }

        var comps = URLComponents(url: Self.apiBase.appendingPathComponent("artist"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(escape(artist))\""),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = comps.url else {
            artistCache[key] = .some(nil)
            return nil
        }

        do {
            let data = try await throttledFetch(url)
            let code = Self.parseCountryCode(from: data)
            artistCache[key] = .some(code)
            return code
        } catch {
            logger.info("countryCode failed for \(artist, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Internal (exposed for @testable tests)

    static func parseFirstReleaseYear(from data: Data) -> Int? {
        struct Envelope: Decodable {
            struct Recording: Decodable {
                let firstReleaseDate: String?
                enum CodingKeys: String, CodingKey {
                    case firstReleaseDate = "first-release-date"
                }
            }
            let recordings: [Recording]?
        }
        guard
            let env = try? JSONDecoder().decode(Envelope.self, from: data),
            let first = env.recordings?.first,
            let date = first.firstReleaseDate,
            date.count >= 4,
            let year = Int(date.prefix(4))
        else { return nil }
        return year
    }

    static func parseCountryCode(from data: Data) -> String? {
        struct Envelope: Decodable {
            struct Artist: Decodable {
                struct Area: Decodable {
                    let isoCodes: [String]?
                    enum CodingKeys: String, CodingKey {
                        case isoCodes = "iso-3166-1-codes"
                    }
                }
                let area: Area?
                let country: String?
            }
            let artists: [Artist]?
        }
        guard
            let env = try? JSONDecoder().decode(Envelope.self, from: data),
            let first = env.artists?.first
        else { return nil }
        // Prefer `area.iso-3166-1-codes[0]`; fall back to top-level `country`.
        return first.area?.isoCodes?.first ?? first.country
    }

    // MARK: - Private

    private func escape(_ s: String) -> String {
        // Lucene escaping — backslash-prefix characters that are syntactic
        // in the MB query DSL. Good-enough set for artist/title inputs.
        var out = ""
        for ch in s {
            if "\\+-&|!(){}[]^\"~*?:/".contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    private func throttledFetch(_ url: URL) async throws -> Data {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            let minGap: TimeInterval = 1.05
            if elapsed < minGap {
                try await Task.sleep(nanoseconds: UInt64((minGap - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt = Date()

        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.badResponse(url)
        }
        return data
    }
}
```

**Step 4: Wire fixtures into the test bundle**

Ensure `RatbatCore/Tests/Fixtures/*.json` is included in the test target. In `project.yml`, the test target should already pick up files under `Fixtures/`; if tests fail with "fixture not found", check that the fixture subfolder is referenced as a resource in `project.yml` → `targets.RatbatCoreTests.sources` or `resources`.

Regenerate the Xcode project after adding files:
```bash
xcodegen generate
```

**Step 5: Run tests**

Expected: all 4 parse tests pass.

**Step 6: Commit**

```bash
git add RatbatCore/Radio/MusicBrainz/ \
        RatbatCore/Tests/MusicBrainzClientTests.swift \
        RatbatCore/Tests/Fixtures/musicbrainz-*.json \
        project.yml Ratbat.xcodeproj
git commit -m "feat: MusicBrainzClient — recording + artist search, 1req/sec rate limit"
```

---

## Phase C — Shared pipeline

### Task 4: `SourceCandidate` + `FacetedPipeline` namespace

**Files:**
- Create: `RatbatCore/Radio/FacetedPipeline.swift`
- Create: `RatbatCore/Tests/FacetedPipelineTests.swift`

**Step 1: Write failing tests for tag-mode + exclusions**

```swift
#if os(macOS)
import XCTest
@testable import RatbatCore

final class FacetedPipelineTests: XCTestCase {

    // MARK: - Tag mode

    func testApplyTagMode_any_unions() {
        let candidates: [(SourceCandidate, Set<String>)] = [
            (candidate(artist: "A", title: "a"), ["techno"]),
            (candidate(artist: "B", title: "b"), ["house"]),
            (candidate(artist: "C", title: "c"), ["techno", "house"]),
        ]
        let query: Set<String> = ["techno", "house"]
        let result = FacetedPipeline.applyTagMode(candidates, required: query, mode: .any)
        XCTAssertEqual(result.count, 3) // all three survive
    }

    func testApplyTagMode_all_intersects() {
        let candidates: [(SourceCandidate, Set<String>)] = [
            (candidate(artist: "A", title: "a"), ["techno"]),
            (candidate(artist: "B", title: "b"), ["house"]),
            (candidate(artist: "C", title: "c"), ["techno", "house"]),
        ]
        let query: Set<String> = ["techno", "house"]
        let result = FacetedPipeline.applyTagMode(candidates, required: query, mode: .all)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.artist, "C")
    }

    // MARK: - Exclusions

    func testApplyExclusions_dropsExcludedArtists() async {
        let cands = [
            candidate(artist: "Keep", title: "k"),
            candidate(artist: "Drop", title: "d"),
        ]
        let out = await FacetedPipeline.applyExclusions(
            cands,
            excludedArtists: ["drop"],
            excludeOwnedLibrary: false,
            tasteProfile: nil
        )
        XCTAssertEqual(out.map(\.artist), ["Keep"])
    }

    // MARK: - Helper

    private func candidate(artist: String, title: String, resolved: URL? = nil) -> SourceCandidate {
        SourceCandidate(
            artist: artist,
            title: title,
            resolvedURL: resolved,
            listenersHint: nil,
            matchedTags: []
        )
    }
}
#endif
```

**Step 2: Run — expected to fail with "no such type" errors.**

**Step 3: Implement `SourceCandidate` + the two simplest pipeline stages**

```swift
import Foundation
import OSLog

/// Common candidate shape across Last.fm and Bandcamp sources. Enables
/// shared post-filter stages in ``FacetedPipeline``.
///
/// The `resolvedURL` field is the key piece of architecture: sources that
/// already know the audio URL (Bandcamp) carry it through, letting
/// ``TrackResolver`` skip YouTube-Music matching.
public struct SourceCandidate: Sendable, Hashable {
    public let artist: String
    public let title: String
    public let resolvedURL: URL?
    public let listenersHint: Int?
    public let matchedTags: Set<String>

    public init(
        artist: String,
        title: String,
        resolvedURL: URL? = nil,
        listenersHint: Int? = nil,
        matchedTags: Set<String> = []
    ) {
        self.artist = artist
        self.title = title
        self.resolvedURL = resolvedURL
        self.listenersHint = listenersHint
        self.matchedTags = matchedTags
    }
}

/// Shared post-filter stages used by both ``LastFMStationController`` and
/// ``BandcampStationController``. Stateless namespace — all state is
/// carried through parameters.
public enum FacetedPipeline {
    static let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "faceted-pipeline")

    // MARK: - Tag mode (stage 2)

    /// Applies `.any` (union) / `.all` (intersection) across the candidate
    /// tags vs the required query tags.
    public static func applyTagMode(
        _ candidates: [(SourceCandidate, Set<String>)],
        required: Set<String>,
        mode: TagMatch
    ) -> [SourceCandidate] {
        switch mode {
        case .any:
            return candidates.map(\.0)
        case .all:
            let lowered = Set(required.map { $0.lowercased() })
            return candidates.compactMap { (cand, tags) in
                let loweredTags = Set(tags.map { $0.lowercased() })
                return loweredTags.isSuperset(of: lowered) ? cand : nil
            }
        }
    }

    // MARK: - Exclusions (stage 5)

    public static func applyExclusions(
        _ candidates: [SourceCandidate],
        excludedArtists: Set<String>,
        excludeOwnedLibrary: Bool,
        tasteProfile: TasteProfile?
    ) async -> [SourceCandidate] {
        let excludedLower = Set(excludedArtists.map { $0.lowercased() })
        var kept: [SourceCandidate] = []
        for c in candidates {
            if excludedLower.contains(c.artist.lowercased()) { continue }
            if excludeOwnedLibrary, let tp = tasteProfile {
                let owned = await tp.libraryContainsArtist(c.artist)
                if owned { continue }
            }
            kept.append(c)
        }
        return kept
    }
}
```

**Step 4: Run tests — both should pass.**

**Step 5: Commit**

```bash
git add RatbatCore/Radio/FacetedPipeline.swift RatbatCore/Tests/FacetedPipelineTests.swift
git commit -m "feat: SourceCandidate + FacetedPipeline.applyTagMode/applyExclusions"
```

---

### Task 5: `FacetedPipeline.applyEraFilter` + `applyRegionFilter`

**Files:**
- Modify: `RatbatCore/Radio/FacetedPipeline.swift`
- Modify: `RatbatCore/Tests/FacetedPipelineTests.swift`

**Step 1: Test with a stub MB client**

Add to `FacetedPipelineTests.swift`:

```swift
// MARK: - Era filter

func testApplyEraFilter_dropsOutOfRange_keepsUnknownWhenFailOpen() async {
    let stub = StubMB(years: [
        "keep — k": 1995,
        "drop — d": 2010,
        // "unknown — u" not mapped → returns nil
    ])
    let cands = [
        candidate(artist: "keep", title: "k"),
        candidate(artist: "drop", title: "d"),
        candidate(artist: "unknown", title: "u"),
    ]
    let out = await FacetedPipeline.applyEraFilter(
        cands,
        yearMin: 1990,
        yearMax: 1999,
        mb: stub
    )
    XCTAssertEqual(Set(out.map(\.artist)), ["keep", "unknown"])
}

func testApplyEraFilter_noRange_returnsAll() async {
    let stub = StubMB(years: [:])
    let cands = [candidate(artist: "a", title: "a")]
    let out = await FacetedPipeline.applyEraFilter(cands, yearMin: nil, yearMax: nil, mb: stub)
    XCTAssertEqual(out.count, 1)
}

// MARK: - Region filter

func testApplyRegionFilter_keepsMatchAndUnknown() async {
    let stub = StubMB(countries: ["JP": ["Japanese Artist"], "BR": ["Brazilian Artist"]])
    let cands = [
        candidate(artist: "Japanese Artist", title: "a"),
        candidate(artist: "Brazilian Artist", title: "b"),
        candidate(artist: "Unknown Artist", title: "c"),
    ]
    let out = await FacetedPipeline.applyRegionFilter(cands, regions: ["JP"], mb: stub)
    XCTAssertEqual(Set(out.map(\.artist)), ["Japanese Artist", "Unknown Artist"])
}

// Stub MB — local test double that implements the same public surface
// the pipeline consumes. Defined as a small protocol so the real
// MusicBrainzClient and this stub both satisfy it.

private actor StubMB: MusicBrainzLookup {
    private let yearMap: [String: Int]
    private let countryMap: [String: String]
    init(years: [String: Int] = [:], countries: [String: [String]] = [:]) {
        self.yearMap = years
        var flat: [String: String] = [:]
        for (code, artists) in countries {
            for a in artists {
                flat[a.lowercased()] = code
            }
        }
        self.countryMap = flat
    }
    func firstReleaseYear(artist: String, title: String) async -> Int? {
        yearMap["\(artist.lowercased()) — \(title.lowercased())"]
    }
    func countryCode(forArtist artist: String) async -> String? {
        countryMap[artist.lowercased()]
    }
}
```

**Step 2: Run — fails because `MusicBrainzLookup` and `applyEraFilter` / `applyRegionFilter` don't exist.**

**Step 3: Add the protocol + filter implementations**

Append to `FacetedPipeline.swift`:

```swift
/// Minimal surface the pipeline needs from a MusicBrainz-style lookup.
/// Lets tests substitute a stub. The real ``MusicBrainzClient`` conforms
/// via an extension in the client file.
public protocol MusicBrainzLookup: Actor {
    func firstReleaseYear(artist: String, title: String) async -> Int?
    func countryCode(forArtist artist: String) async -> String?
}

extension FacetedPipeline {
    // MARK: - Era filter (stage 6)

    /// Drops candidates whose MB-reported release year falls outside the
    /// configured range. Candidates with unknown year (MB said nothing)
    /// are **kept** — fail-open per the design doc, since MB coverage on
    /// Bandcamp bedroom-producer material is ~50%.
    public static func applyEraFilter(
        _ candidates: [SourceCandidate],
        yearMin: Int?,
        yearMax: Int?,
        mb: MusicBrainzLookup
    ) async -> [SourceCandidate] {
        guard yearMin != nil || yearMax != nil else { return candidates }
        let lo = yearMin ?? Int.min
        let hi = yearMax ?? Int.max

        var kept: [SourceCandidate] = []
        for c in candidates {
            if let y = await mb.firstReleaseYear(artist: c.artist, title: c.title) {
                if y >= lo && y <= hi { kept.append(c) }
            } else {
                kept.append(c) // unknown → keep (fail-open)
            }
        }
        logger.info("era filter \(lo, privacy: .public)..\(hi, privacy: .public): \(candidates.count) → \(kept.count)")
        return kept
    }

    // MARK: - Region filter (stage 7)

    public static func applyRegionFilter(
        _ candidates: [SourceCandidate],
        regions: [String],
        mb: MusicBrainzLookup
    ) async -> [SourceCandidate] {
        guard !regions.isEmpty else { return candidates }
        let allowed = Set(regions.map { $0.uppercased() })

        var kept: [SourceCandidate] = []
        // Dedup artist lookups — one MB call per unique artist, not per
        // track. Pipeline refills can have 3-5 tracks per artist easily.
        var artistCode: [String: String?] = [:]

        for c in candidates {
            let key = c.artist.lowercased()
            let code: String?
            if let cached = artistCode[key] {
                code = cached
            } else {
                code = await mb.countryCode(forArtist: c.artist)
                artistCode[key] = .some(code)
            }
            if let code {
                if allowed.contains(code.uppercased()) { kept.append(c) }
            } else {
                kept.append(c) // unknown → keep (fail-open)
            }
        }
        logger.info("region filter \(allowed.sorted().joined(separator: ","), privacy: .public): \(candidates.count) → \(kept.count)")
        return kept
    }
}
```

**Step 4: Make `MusicBrainzClient` conform**

Add at the bottom of `MusicBrainzClient.swift`:
```swift
extension MusicBrainzClient: MusicBrainzLookup {}
```
(No code needed — the two methods already match the protocol.)

**Step 5: Run tests — all should pass.**

**Step 6: Commit**

```bash
git add RatbatCore/Radio/FacetedPipeline.swift \
        RatbatCore/Radio/MusicBrainz/MusicBrainzClient.swift \
        RatbatCore/Tests/FacetedPipelineTests.swift
git commit -m "feat: FacetedPipeline era + region filters (fail-open on unknown)"
```

---

## Phase D — Refactor `LastFMStationController`

### Task 6: Rewire controller through `FacetedPipeline`

This is the biggest refactor task. The existing stages 2 (tag-mode), 5 (exclusions) are replaced by `FacetedPipeline` calls. Stages 3 (popularity) and 4 (precision) stay in the controller as Last.fm-specific. Stages 6-7 (MB era + region) are new.

**Files:**
- Modify: `RatbatCore/Radio/LastFM/LastFMStationController.swift`

**Step 1: Write an integration-level test in `LastFMStationControllerTests.swift` (if it exists; else skip to implementation)**

The existing tests may not cover the pipeline stages directly — this refactor is covered primarily by `FacetedPipelineTests` + the migration tests. Skim existing controller tests; if any break due to config shape changes, update them.

**Step 2: Refactor `refillPool()`**

In `LastFMStationController.swift`, the current `refillPool()` has 7 stages inline. Keep stages 1 (fetch), 3 (popularity), 4 (precision) in the controller; delegate stages 2, 5, 6, 7, 8 to `FacetedPipeline`.

Key changes:
- Change `private var pool: [LastFMClient.TrackCandidate]` to `[SourceCandidate]`.
- Convert `LastFMClient.TrackCandidate` to `SourceCandidate` after stage 4 (precision), carrying `matchedTags` and `listenersHint` through.
- Replace the exclusions-loop (current stage 4 in the code) with `FacetedPipeline.applyExclusions(...)`.
- After the existing stages 1-4 produce candidates, call in sequence:
  ```swift
  var cands = convertToSourceCandidates(survivors, tagHits: tagHits)
  cands = await FacetedPipeline.applyExclusions(cands,
      excludedArtists: config.query.excludedArtists,
      excludeOwnedLibrary: config.query.excludeOwnedLibrary,
      tasteProfile: tasteProfile)
  cands = await FacetedPipeline.applyEraFilter(cands,
      yearMin: config.query.yearMin,
      yearMax: config.query.yearMax,
      mb: musicBrainz)
  cands = await FacetedPipeline.applyRegionFilter(cands,
      regions: config.query.regions,
      mb: musicBrainz)
  ```
- The taste-score + wildcard-shuffle step (current stage 6-7 in the code) stays in the controller for now — it's not yet extracted into the pipeline. **Or**: extract it as `FacetedPipeline.scoreAndShuffle(_:tasteProfile:history:stationID:wildcardFraction:)`. Your call; extracting makes Task 15 (Bandcamp controller) trivial.
- Inject a `MusicBrainzClient` (or protocol-typed `MusicBrainzLookup`) via the initializer alongside existing dependencies.

Example new initializer:
```swift
public init(
    config: LastFMStationConfig,
    client: LastFMClient,
    musicBrainz: MusicBrainzClient,
    history: HistoryStore,
    resolver: TrackResolver,
    tasteProfile: TasteProfile
) { ... }
```

**Step 3: Update call sites in `StationManager` / `RadioBroadcaster`**

Anywhere `LastFMStationController(...)` is constructed, pass a `MusicBrainzClient`. The station-broadcasting code probably has one owning holder — add MB there.

Check `RatbatCore/Radio/StationManager.swift` and `RatbatCore/Radio/RadioBroadcaster.swift`.

**Step 4: Update precision logic to use `config.query.genreTags`**

Current code reads `config.tags` for the query-tag set. Replace with `config.query.genreTags`. The precision check at line 230 (`!topTags.isDisjoint(with: queryTagsLower)`) stays — it's now provably safe because `genreTags` excludes temporal and regional tags.

**Step 5: Run the whole test suite**

```bash
xcodebuild test -project Ratbat.xcodeproj -scheme Ratbat -destination 'platform=macOS' 2>&1 | tail -40
```

Expected: all tests green.

**Step 6: Manual smoke test**

Delete any existing `.ratbat-stations.json` backup and let the app decode a legacy-shape config. Create a new station via the UI (still on the old UI — new UI ships in Phase G). Confirm broadcast works end-to-end. You'll need a MusicBrainz-initialized broadcaster so era/region filtering can engage even if both are empty (no-op path).

**Step 7: Commit**

```bash
git add RatbatCore/Radio/LastFM/LastFMStationController.swift \
        RatbatCore/Radio/StationManager.swift \
        RatbatCore/Radio/RadioBroadcaster.swift
git commit -m "refactor: LastFMStationController through FacetedPipeline; era/region enforced via MB"
```

---

## Phase E — Bandcamp client

### Task 7: `BandcampClient` with fixture-HTML parse tests

**Files:**
- Create: `RatbatCore/Radio/Bandcamp/BandcampClient.swift`
- Create: `RatbatCore/Tests/BandcampClientTests.swift`
- Create: `RatbatCore/Tests/Fixtures/bandcamp-tag-techno.html`

**Step 1: Capture a fixture from a live Bandcamp tag page**

```bash
curl -sS -A 'Ratbat/1.0 (jns.johansson@gmail.com)' \
  'https://bandcamp.com/tag/techno?sort_field=date' \
  > RatbatCore/Tests/Fixtures/bandcamp-tag-techno.html
```

Open the file, search for `pagedata` or `data-blob` to confirm the JSON-blob shape is present. If Bandcamp has restructured, adjust the parser in Step 3 accordingly. **If you can't find a JSON blob with the expected keys (`items`, `artist`, `title`, `tralbum_url`), stop and raise a flag before continuing — the scrape design assumes that shape.**

**Step 2: Write a parse test**

```swift
#if os(macOS)
import XCTest
@testable import RatbatCore

final class BandcampClientTests: XCTestCase {

    func testParseTagPage_extractsArtistTitleURL() throws {
        let html = try fixtureHTML("bandcamp-tag-techno")
        let releases = BandcampClient.parseTagPage(html: html)
        XCTAssertGreaterThan(releases.count, 0, "fixture must contain at least one release")
        let first = releases[0]
        XCTAssertFalse(first.artist.isEmpty)
        XCTAssertFalse(first.title.isEmpty)
        XCTAssertEqual(first.releaseURL.scheme, "https")
    }

    private func fixtureHTML(_ name: String) throws -> String {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "html") else {
            throw XCTSkip("Fixture \(name).html missing")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
#endif
```

**Step 3: Implement `BandcampClient`**

```swift
import Foundation
import OSLog

public struct BandcampRelease: Sendable, Hashable {
    public let artist: String
    public let title: String
    public let releaseURL: URL
    public let releaseDate: Date?
}

public actor BandcampClient {

    public enum Error: Swift.Error, Sendable {
        case badResponse(URL)
        case parseFailed(URL)
    }

    public enum Sort: String, Sendable, Codable, Hashable {
        case date
        case pop
    }

    private let userAgent: String
    private let session: URLSession
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "bandcamp")
    private var lastRequestAt: Date?

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    // MARK: - Public

    public func releases(forTag tag: String, sort: Sort = .date, maxPages: Int = 5) async throws -> [BandcampRelease] {
        var all: [BandcampRelease] = []
        let slug = tag.lowercased().replacingOccurrences(of: " ", with: "-")
        for page in 1...maxPages {
            var comps = URLComponents(string: "https://bandcamp.com/tag/\(slug)")!
            comps.queryItems = [
                URLQueryItem(name: "sort_field", value: sort.rawValue),
                URLQueryItem(name: "page", value: "\(page)"),
            ]
            guard let url = comps.url else { break }
            do {
                let html = try await throttledFetch(url)
                let page = Self.parseTagPage(html: html)
                if page.isEmpty { break } // past the end
                all.append(contentsOf: page)
            } catch {
                logger.info("bandcamp tag \(tag, privacy: .public) page \(page): \(String(describing: error), privacy: .public)")
                break
            }
        }
        logger.info("bandcamp releases(tag: \(tag, privacy: .public)): \(all.count)")
        return all
    }

    // MARK: - Internal (exposed for tests)

    /// Scrape the `pagedata` data-blob out of the HTML and JSON-decode it.
    /// Returns `[]` if the blob can't be found — treated as "tag page is
    /// structurally different than we expect" by callers.
    static func parseTagPage(html: String) -> [BandcampRelease] {
        // Look for `data-blob="..."` on the pagedata div. The value is
        // URL-encoded JSON (HTML-attribute-escaped).
        guard let blob = extractDataBlob(from: html) else { return [] }
        guard let data = blob.data(using: .utf8) else { return [] }

        struct Envelope: Decodable {
            struct Item: Decodable {
                let artist: String?
                let title: String?
                let tralbumURL: String?
                let releaseDate: String?
                enum CodingKeys: String, CodingKey {
                    case artist, title
                    case tralbumURL = "tralbum_url"
                    case releaseDate = "release_date"
                }
            }
            // The real JSON nests items under a `hub.tabs[].collections[].items`
            // or similar; adjust when the fixture is captured. Placeholder:
            let items: [Item]?
        }

        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        let iso = ISO8601DateFormatter()
        let items = env.items ?? []
        return items.compactMap { item in
            guard
                let artist = item.artist, !artist.isEmpty,
                let title = item.title, !title.isEmpty,
                let urlStr = item.tralbumURL, let url = URL(string: urlStr)
            else { return nil }
            let date: Date? = item.releaseDate.flatMap { iso.date(from: $0) }
            return BandcampRelease(artist: artist, title: title, releaseURL: url, releaseDate: date)
        }
    }

    private static func extractDataBlob(from html: String) -> String? {
        // `<div id="pagedata" data-blob="...">` — the `...` is HTML-attr
        // escaped JSON. Unescape the three HTML entities that matter here.
        guard let range = html.range(of: #"id="pagedata""#) else { return nil }
        let afterID = html[range.upperBound...]
        guard let blobRange = afterID.range(of: #"data-blob=""#) else { return nil }
        let afterOpenQuote = afterID[blobRange.upperBound...]
        guard let endQuote = afterOpenQuote.firstIndex(of: "\"") else { return nil }
        let escaped = String(afterOpenQuote[..<endQuote])
        return escaped
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: - Private

    private func throttledFetch(_ url: URL) async throws -> String {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            let minGap: TimeInterval = 0.5
            if elapsed < minGap {
                try await Task.sleep(nanoseconds: UInt64((minGap - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.badResponse(url)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw Error.parseFailed(url)
        }
        return html
    }
}
```

> **Heads-up for the engineer:** the exact JSON shape inside `data-blob` may nest differently than the `items: [...]` at the top level shown above. Once you have the fixture, adjust the `Envelope` struct to match — keep the parse test green. This is the one point where the plan is guaranteed to need real-world adjustment.

**Step 4: Run — fixture test should pass.**

**Step 5: Commit**

```bash
git add RatbatCore/Radio/Bandcamp/ \
        RatbatCore/Tests/BandcampClientTests.swift \
        RatbatCore/Tests/Fixtures/bandcamp-tag-techno.html
git commit -m "feat: BandcampClient — tag-page scrape with JSON-blob extraction"
```

---

## Phase F — Bandcamp station kind + controller

### Task 8: `BandcampStationConfig` + `Station.Kind.bandcamp`

**Files:**
- Create: `RatbatCore/Radio/Bandcamp/BandcampStationConfig.swift`
- Modify: `RatbatCore/Radio/Station.swift`
- Modify: `RatbatCore/Tests/StationKindTests.swift`
- Modify: `RatbatCore/Tests/StationTests.swift`

**Step 1: Write config round-trip test**

Create `RatbatCore/Tests/BandcampStationConfigTests.swift`:

```swift
#if os(macOS)
import XCTest
@testable import RatbatCore

final class BandcampStationConfigTests: XCTestCase {
    func testRoundTrip_preservesAllFields() throws {
        let cfg = BandcampStationConfig(
            name: "Dungeon Synth",
            query: FacetedQuery(genreTags: ["dungeon synth"], yearMin: 2020),
            sort: .date
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(BandcampStationConfig.self, from: data)
        XCTAssertEqual(decoded.name, "Dungeon Synth")
        XCTAssertEqual(decoded.query.genreTags, ["dungeon synth"])
        XCTAssertEqual(decoded.query.yearMin, 2020)
        XCTAssertEqual(decoded.sort, .date)
    }

    func testDefaults_sortIsDate() {
        let cfg = BandcampStationConfig(name: "T", query: FacetedQuery(genreTags: ["techno"]))
        XCTAssertEqual(cfg.sort, .date)
    }
}
#endif
```

**Step 2: Implement config**

`BandcampStationConfig.swift`:

```swift
import Foundation

public struct BandcampStationConfig: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var query: FacetedQuery
    public var sort: BandcampClient.Sort
    public var shufflePool: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        query: FacetedQuery,
        sort: BandcampClient.Sort = .date,
        shufflePool: Bool = true
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.sort = sort
        self.shufflePool = shufflePool
    }
}
```

**Step 3: Extend `Station.Kind`**

In `RatbatCore/Radio/Station.swift`, add:
```swift
case bandcamp(config: BandcampStationConfig)
```
to the `Kind` enum.

Add a convenience accessor + factory, mirroring the existing Last.fm ones:

```swift
public var bandcampConfig: BandcampStationConfig? {
    if case let .bandcamp(c) = kind { return c }
    return nil
}

public static func fromBandcamp(_ config: BandcampStationConfig) -> Station {
    Station(id: config.id, name: config.name, kind: .bandcamp(config: config))
}
```

Add/update the Station.Kind tests. At minimum, add a round-trip:

```swift
func testStationKind_bandcamp_roundTrips() throws {
    let cfg = BandcampStationConfig(name: "X", query: FacetedQuery(genreTags: ["t"]))
    let station = Station.fromBandcamp(cfg)
    let data = try JSONEncoder().encode(station)
    let decoded = try JSONDecoder().decode(Station.self, from: data)
    XCTAssertEqual(decoded.bandcampConfig?.name, "X")
}
```

**Step 4: Run — all tests pass.**

**Step 5: Commit**

```bash
git add RatbatCore/Radio/Bandcamp/BandcampStationConfig.swift \
        RatbatCore/Radio/Station.swift \
        RatbatCore/Tests/
git commit -m "feat: BandcampStationConfig + Station.Kind.bandcamp case"
```

---

### Task 9: `BandcampStationController`

**Files:**
- Create: `RatbatCore/Radio/Bandcamp/BandcampStationController.swift`

**Step 1: Sketch the controller**

Structurally mirrors `LastFMStationController` but with simpler seed fetch (no tag-mode split across API calls — we scrape per tag and union/intersect client-side via `FacetedPipeline.applyTagMode`).

```swift
import Foundation
import OSLog

public actor BandcampStationController: TrackSource {

    public enum Error: Swift.Error, Sendable {
        case poolExhausted
        case noTracksForTags([String])
    }

    private let config: BandcampStationConfig
    private let client: BandcampClient
    private let musicBrainz: MusicBrainzClient
    private let history: HistoryStore
    private let resolver: TrackResolver
    private let tasteProfile: TasteProfile
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "bandcamp-station")

    private var pool: [SourceCandidate] = []
    private var cursor: Int = 0

    public init(
        config: BandcampStationConfig,
        client: BandcampClient,
        musicBrainz: MusicBrainzClient,
        history: HistoryStore,
        resolver: TrackResolver,
        tasteProfile: TasteProfile
    ) {
        self.config = config
        self.client = client
        self.musicBrainz = musicBrainz
        self.history = history
        self.resolver = resolver
        self.tasteProfile = tasteProfile
    }

    // MARK: - TrackSource

    public func nextURL() async throws -> TrackSourceItem? {
        while true {
            if cursor >= pool.count {
                try await refillPool()
                cursor = 0
                if pool.isEmpty { return nil }
            }
            let cand = pool[cursor]
            cursor += 1

            // Dedup against history on this station
            if await history.hasPlayed(artist: cand.artist, title: cand.title, stationID: config.id) {
                continue
            }

            // Resolve via TrackResolver — the direct-URL shortcut (Task 10)
            // means yt-dlp gets the Bandcamp release URL straight from the
            // candidate instead of re-searching.
            guard let resolved = await resolver.resolve(candidate: cand) else {
                continue
            }
            let hid = await history.record(
                artist: cand.artist,
                title: cand.title,
                stationID: config.id
            )
            return TrackSourceItem(
                url: resolved,
                artist: cand.artist,
                title: cand.title,
                historyID: hid
            )
        }
    }

    // MARK: - Pool refill

    private func refillPool() async throws {
        // Stage 1: per-tag scrape
        var tagHits: [String: (SourceCandidate, Set<String>)] = [:]
        for tag in config.query.genreTags {
            do {
                let releases = try await client.releases(forTag: tag, sort: config.sort)
                for r in releases {
                    let key = "\(r.artist.lowercased())\u{1}\(r.title.lowercased())"
                    var existing = tagHits[key] ?? (
                        SourceCandidate(
                            artist: r.artist,
                            title: r.title,
                            resolvedURL: r.releaseURL,
                            matchedTags: []
                        ),
                        Set<String>()
                    )
                    existing.1.insert(tag.lowercased())
                    tagHits[key] = existing
                }
            } catch {
                logger.info("scrape failed for tag \(tag, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if tagHits.isEmpty {
            throw Error.noTracksForTags(config.query.genreTags)
        }

        // Stage 2: tag mode
        let required = Set(config.query.genreTags.map { $0.lowercased() })
        var cands = FacetedPipeline.applyTagMode(
            Array(tagHits.values),
            required: required,
            mode: config.query.tagMatch
        )

        // Stage 5: exclusions (cheap)
        cands = await FacetedPipeline.applyExclusions(
            cands,
            excludedArtists: config.query.excludedArtists,
            excludeOwnedLibrary: config.query.excludeOwnedLibrary,
            tasteProfile: tasteProfile
        )

        // Stage 6-7: MB era + region filters
        cands = await FacetedPipeline.applyEraFilter(
            cands,
            yearMin: config.query.yearMin,
            yearMax: config.query.yearMax,
            mb: musicBrainz
        )
        cands = await FacetedPipeline.applyRegionFilter(
            cands,
            regions: config.query.regions,
            mb: musicBrainz
        )

        // Stage 8: shuffle (no taste score for v1; add in follow-up if wanted)
        if config.shufflePool { cands.shuffle() }

        pool = cands
        logger.info("bandcamp pool refilled: \(cands.count)")
    }
}
```

**Step 2: Wire into `StationManager`**

Add a `createBandcamp(_ config: BandcampStationConfig)` method alongside `createLastFM`. Pattern-match where `RadioBroadcaster` picks a controller per `Station.Kind` and add the `.bandcamp` case.

**Step 3: Smoke test**

No unit test yet (integration work covered by `FacetedPipelineTests` + `BandcampClientTests`). Manual: create a Bandcamp station via a debug action or programmatic test; confirm `refillPool()` returns non-empty.

**Step 4: Commit**

```bash
git add RatbatCore/Radio/Bandcamp/BandcampStationController.swift \
        RatbatCore/Radio/StationManager.swift \
        RatbatCore/Radio/RadioBroadcaster.swift
git commit -m "feat: BandcampStationController — scrape → pipeline → TrackSource"
```

---

## Phase G — TrackResolver direct-URL shortcut

### Task 10: Pre-resolved URL bypass in `TrackResolver`

**Files:**
- Modify: `RatbatCore/Radio/TrackResolver.swift` (or wherever the resolver actor lives — verify via `grep -rn "class TrackResolver\|struct TrackResolver\|actor TrackResolver" RatbatCore/`)
- Modify: `RatbatCore/Tests/TrackResolverTests.swift`

**Step 1: Write a failing test**

```swift
func testResolve_directURL_skipsYouTubeMatching() async throws {
    let resolver = TrackResolver(/* existing deps */)
    let cand = SourceCandidate(
        artist: "Test",
        title: "Song",
        resolvedURL: URL(string: "https://example.bandcamp.com/track/song")!
    )
    let result = await resolver.resolve(candidate: cand)
    // Expect the resolver to hand yt-dlp the Bandcamp URL directly; we
    // assert some observable behaviour — depending on resolver shape this
    // might be a spy on the subprocess invocation, or a stubbed yt-dlp.
    XCTAssertNotNil(result)
}
```

Adjust the spy/stub pattern to match how existing `TrackResolverTests` exercises the subprocess pipeline. If the resolver invokes yt-dlp via a pluggable runner, stub that runner and assert the command line contains the Bandcamp URL directly (no YT Music search step).

**Step 2: Implement the shortcut**

In the resolver, the top of the `resolve(...)` method currently runs a YT Music search. Add a branch at the top:

```swift
public func resolve(candidate: SourceCandidate) async -> URL? {
    // Direct-URL path — source has already resolved the audio origin
    // (e.g., Bandcamp). Skip YT Music matching and hand the URL straight
    // to yt-dlp.
    if let pre = candidate.resolvedURL {
        return await ytdlpDownload(from: pre, artist: candidate.artist, title: candidate.title)
    }
    // ...existing YT Music search + match + download path...
}
```

`ytdlpDownload` is the existing yt-dlp invocation wrapped to take a URL directly. If that function doesn't exist, factor it out of the current flow — the yt-dlp step is already there; only the input source changes.

If the current `resolve(...)` takes `(artist, title)` as input (and not `SourceCandidate`), add an overload. Keep the old entry point working — `LastFMStationController` still calls `resolve(artist:title:)` and doesn't need the shortcut.

**Step 3: Run tests — new test passes; existing resolver tests still pass.**

**Step 4: Commit**

```bash
git add RatbatCore/Radio/TrackResolver.swift RatbatCore/Tests/TrackResolverTests.swift
git commit -m "feat: TrackResolver direct-URL shortcut for sources with pre-resolved audio"
```

---

## Phase H — UI

### Task 11: Shared `FacetedQueryEditor` SwiftUI subview

**Files:**
- Create: `RatbatCore/Views/FacetedQueryEditor.swift`

**Step 1: Build the subview**

No TDD on SwiftUI subviews — driven by visual iteration. Design points:
- Bound to a `Binding<FacetedQuery>`.
- Genre section: curated palette grid + free-text "Add tag..." TextField.
- Era section: two numeric TextFields, From / To.
- Region section: multi-select chip row + popover picker backed by `Locale.isoRegionCodes`.

Sketch:

```swift
#if os(macOS)
import SwiftUI

public struct FacetedQueryEditor: View {
    @Binding var query: FacetedQuery
    let palette: [String]           // source-specific curated tags

    @State private var freeTextTag: String = ""
    @State private var yearMinString: String = ""
    @State private var yearMaxString: String = ""
    @State private var regionPopoverOpen: Bool = false

    public init(query: Binding<FacetedQuery>, palette: [String]) {
        self._query = query
        self.palette = palette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            genreSection
            eraSection
            regionSection
        }
        .onAppear {
            yearMinString = query.yearMin.map(String.init) ?? ""
            yearMaxString = query.yearMax.map(String.init) ?? ""
        }
    }

    // MARK: - Sections

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Genre").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 4)], spacing: 4) {
                ForEach(palette, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(
                        get: { query.genreTags.contains(tag) },
                        set: { isOn in
                            if isOn, !query.genreTags.contains(tag) { query.genreTags.append(tag) }
                            else { query.genreTags.removeAll { $0 == tag } }
                        }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }
            HStack {
                TextField("Add tag…", text: $freeTextTag, onCommit: addFreeText)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addFreeText() }
                    .disabled(freeTextTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !customTags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(customTags, id: \.self) { tag in
                        Label(tag, systemImage: "xmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .onTapGesture { query.genreTags.removeAll { $0 == tag } }
                    }
                }
            }
        }
    }

    private var eraSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Era (optional)").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("1990", text: $yearMinString).frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: yearMinString) { query.yearMin = Int($0) }
                Text("—")
                TextField("1999", text: $yearMaxString).frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: yearMaxString) { query.yearMax = Int($0) }
            }
        }
    }

    private var regionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Region (optional)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(query.regions, id: \.self) { code in
                    Label(Locale.current.localizedString(forRegionCode: code) ?? code,
                          systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .onTapGesture { query.regions.removeAll { $0 == code } }
                }
                Button("+ Add region") { regionPopoverOpen.toggle() }
                    .popover(isPresented: $regionPopoverOpen) {
                        RegionPicker { code in
                            if !query.regions.contains(code) { query.regions.append(code) }
                            regionPopoverOpen = false
                        }
                    }
            }
        }
    }

    // MARK: - Helpers

    private var customTags: [String] {
        query.genreTags.filter { !palette.contains($0) }
    }

    private func addFreeText() {
        let t = freeTextTag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !query.genreTags.contains(t) else {
            freeTextTag = ""
            return
        }
        query.genreTags.append(t)
        freeTextTag = ""
    }
}

private struct RegionPicker: View {
    let onPick: (String) -> Void
    @State private var search: String = ""

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(filtered, id: \.self) { code in
                Button {
                    onPick(code)
                } label: {
                    HStack {
                        Text(Locale.current.localizedString(forRegionCode: code) ?? code)
                        Spacer()
                        Text(code).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }.frame(width: 280, height: 320)
        }
    }

    private var filtered: [String] {
        let all = Locale.isoRegionCodes
        if search.isEmpty { return all }
        let q = search.lowercased()
        return all.filter { code in
            code.lowercased().contains(q)
                || (Locale.current.localizedString(forRegionCode: code) ?? "").lowercased().contains(q)
        }
    }
}
#endif
```

**Step 2: Verify manually** — drop it into a preview or a throwaway view and confirm the three sections render + interact correctly.

**Step 3: Commit**

```bash
git add RatbatCore/Views/FacetedQueryEditor.swift
git commit -m "feat: FacetedQueryEditor — shared SwiftUI subview for genre/era/region facets"
```

---

### Task 12: Migrate `AddLastFMStationView` to use `FacetedQueryEditor`

**Files:**
- Modify: `RatbatCore/Views/AddLastFMStationView.swift`

Rewrite the sheet to use `FacetedQueryEditor` for the shared fields. Keep Last.fm-specific controls (popularity tier, tag-match) in a `DisclosureGroup` below. Remove the Precision picker entirely (it's gone from the config).

The `create()` method now builds:
```swift
var query = editingQuery   // from @State var editingQuery = FacetedQuery(genreTags: [])
let config = LastFMStationConfig(name: trimmedName, query: query, shufflePool: true)
stations.createLastFM(config)
```

The Last.fm palette (line 42 of the current file — `availableTags`) gets passed into `FacetedQueryEditor(query: $query, palette: palette)`.

Commit:
```bash
git commit -am "refactor: AddLastFMStationView uses FacetedQueryEditor; precision UI removed"
```

---

### Task 13: Create `AddBandcampStationView`

**Files:**
- Create: `RatbatCore/Views/AddBandcampStationView.swift`
- Modify: `RatbatCore/Views/PlaylistsSidebarView.swift` (add "New Bandcamp Station" entry)

**Step 1: Build the sheet**

Mirror `AddLastFMStationView` in shape. Curated palette leans into Bandcamp's long-tail scene tags:

```swift
private static let palette: [String] = [
    "techno", "house", "ambient", "dungeon synth",
    "vaporwave", "hyperpop", "drone", "dub techno",
    "outsider house", "IDM", "breakcore", "footwork",
    "witch house", "hauntology", "slowcore", "shoegaze",
    "post-rock", "field recording", "lo-fi", "experimental"
]
```

Source-specific section: `Sort` picker (Date / Popularity).

The rest is structurally identical to `AddLastFMStationView` post-Task 12.

**Step 2: Wire it into the sidebar**

`PlaylistsSidebarView.swift` has a menu/button for "New Last.fm Station" — add a sibling "New Bandcamp Station" action that opens `AddBandcampStationView`.

**Step 3: Commit**

```bash
git commit -am "feat: AddBandcampStationView + sidebar entry"
```

---

### Task 14: Bandcamp station detail view + sidebar icon

**Files:**
- Create: `RatbatCore/Views/BandcampStationDetailView.swift`
- Modify: `RatbatCore/Views/RootView.swift` (route `.bandcamp(let cfg)` to the new detail view)
- Modify: wherever sidebar icons are chosen per-`Station.Kind` (`PlaylistsSidebarView.swift` likely)

Mirror `LastFMStationDetailView`. Pick an SF Symbol — `waveform` or `cassette.fill` — and surface the query facets (genre tags, year range, regions) as read-only chips, matching the Last.fm detail style.

Commit:
```bash
git commit -am "feat: BandcampStationDetailView + sidebar icon for .bandcamp kind"
```

---

## Phase I — Integration + polish

### Task 15: End-to-end smoke test

**Steps:**
1. Launch the rebuilt app: `./install.sh`
2. Create a Bandcamp station with `genre=techno`, `region=JP`, sort=date.
3. Start broadcast. Watch OSLog:
   ```bash
   /usr/bin/log stream --predicate 'subsystem == "se.jonasjohansson.ratbat"' --level info --style compact
   ```
4. Verify stage boundaries show candidate cardinality drops sensibly (e.g. `era filter ... → N`, `region filter JP: N → M`).
5. Listen. Expect Japanese techno. Skip a few; confirm no Brazilian samba.
6. Create a Last.fm station with the same facets (`techno` + `1990s` decade stored as `yearMin=1990, yearMax=1999` + `regions=["JP"]`).
7. Confirm the Exaltasamba regression is gone.

**If anything fails**: the OSLog shows which stage ate the candidates. `MusicBrainzClient` logs rate-limiting decisions too — if you see "era filter 1990..1999: 200 → 0", MB is likely returning `nil` for everything; check User-Agent header and rate-limit gaps.

### Task 16: (Optional) Legacy decade-tag migration enhancement

The Task 2 migration carries legacy `"2000s"`-style tags into `query.genreTags` verbatim — they stay as string tags. A nicer migration would detect them and lift into `yearMin`/`yearMax`:

```swift
// Inside LastFMStationConfig.init(from:), after building the faceted query:
for tag in self.query.genreTags where tag.range(of: #"^\d{4}s$"#, options: .regularExpression) != nil {
    let decade = Int(tag.prefix(4))!
    self.query.yearMin = min(self.query.yearMin ?? decade, decade)
    self.query.yearMax = max(self.query.yearMax ?? decade + 9, decade + 9)
}
self.query.genreTags.removeAll { $0.range(of: #"^\d{4}s$"#, options: .regularExpression) != nil }
```

Add a test asserting that a legacy config with `"tags": ["techno", "1990s"]` hydrates to `genreTags: ["techno"], yearMin: 1990, yearMax: 1999`.

Commit:
```bash
git commit -am "feat: migration lifts decade tags into yearMin/yearMax on legacy decode"
```

---

## Completion

When all tasks are done:
1. Run the full test suite one more time. All green.
2. Merge the feature branch (or open a PR from the worktree).
3. Deploy to the Mac Mini via `./install.sh` (covered by `docs/mac-mini-setup.md`).
4. Delete this plan file or move to `docs/plans/archive/` — the design doc stays.

**Open follow-ups** (intentionally out of scope, per the design):
- Label follow-list station kind (v2)
- Unified "New Generative Station" sheet (revisit once UX settles)
- Disk-persisted MusicBrainz cache (startup latency only)
