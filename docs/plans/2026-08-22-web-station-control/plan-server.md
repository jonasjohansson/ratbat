# Ratbat — Server-Side Implementation Plan: Web Station CRUD, Steering, Transparency, Infra Hardening

All paths relative to `/private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat` unless absolute. Verified against `origin/main` (`adeecbb`). Line refs are current-file, pre-change.

Steps are ordered and independently shippable — each ends with a green test suite and a deployable app. Steps 0–1 are prerequisites for everything after; 2–9 can land in any order after 1, except 3 requires 2 and 9 requires 8's controller seam only if boost-steering of library radio is wanted at birth (it isn't required).

---

## Step 0 — Prerequisite bug fixes (5 independent micro-PRs)

### 0a. Status-text table additions
`RatbatCore/Radio/RadioBroadcaster.swift:2286-2296`, `buildHTTPResponse` switch. Add:
```swift
case 201: statusText = "Created"
case 403: statusText = "Forbidden"
case 410: statusText = "Gone"
case 422: statusText = "Unprocessable Content"
```
(409 already present.) Today the wire literally reads `HTTP/1.1 403 Unknown`.
**Test:** extend `testActionsRejectGuestsWith403` (RadioBroadcasterTests.swift:1238) to assert `HTTP/1.1 403 Forbidden`; add a unit test asserting `buildHTTPResponse(status: 422, …)` starts with `HTTP/1.1 422 Unprocessable Content`.

### 0b. `/history` prefix-match tightening
`RadioBroadcaster.swift:1808`: replace `if path.hasPrefix("/history")` with
```swift
if path == "/history" || path.hasPrefix("/history?")
```
**Test:** raw-socket `GET /historyxyz` → expect `404` (use `Self.fetchRawResponse`, the pattern at RadioBroadcasterTests.swift:951).

### 0c. Empty-pipelines listener rebind hole
Two coordinated edits — **must land before any web-driven stop ships**:
1. `scheduleListenerRebind` (`RadioBroadcaster.swift:1456`): delete the `guard !pipelines.isEmpty else { return }` early-return **and** the matching re-check inside the rebind Task (`guard !self.pipelines.isEmpty` a few lines below). Rationale to write in the comment: once the listener also serves the control plane (`/stations/*`), "nothing to serve" is no longer true at zero pipelines — a dead socket at zero stations means the web can never start one again.
2. `startBroadcast` (`RadioBroadcaster.swift:956`): before `if listener == nil`, add a defensive recreate:
```swift
if let l = listener, l.state == .failed || l.state == .cancelled {
    l.cancel()
    listener = nil
}
```
so a desktop start also recovers a failed-but-non-nil listener.
**Test:** mirror `testListenerRecoversFromABindConflict` (RadioBroadcasterTests.swift:361) but stop every station via `stopBroadcast(stationID:)` (NOT `stopAll`), force the listener into failure the same way that test does, wait past `listenerRebindDelay(forAttempt: 1)`, assert `GET /now.json` answers again.

### 0d. autoStartSlugs re-key on rename
Slug derives from name (`Station.swift:149-162`); `registerStations` re-keys only the live record (`RadioBroadcaster.swift:1198-1206`); `autoStartSlugs` is silently orphaned, live or idle.
- `RatbatCore/Radio/StationManager.swift`: add `public var slugDidChange: ((_ old: String, _ new: String) -> Void)?`. Fire it in `rename(_:to:)` (and later in `applyUpdate`, Step 2) whenever the computed slug changes.
- `RatbatCore/Views/RootView.swift` (in `init` or the `.task` at :185, once): 
```swift
stations.slugDidChange = { old, new in
    if BroadcastPreferences.shared.isAutoStart(slug: old) {
        BroadcastPreferences.shared.setAutoStart(false, slug: old)
        BroadcastPreferences.shared.setAutoStart(true, slug: new)
    }
}
```
(`setAutoStart` is idempotent, BroadcastPreferences.swift:229.)
**Test:** StationManagerTests — rename a station, assert the closure fires with old/new slugs; BroadcastPreferencesTests-style assertion that re-key preserves membership.

### 0e. Edit vs Add parity (desktop, before mirroring to web)
`RatbatCore/Views/EditStationView.swift` claims "the same controls in the same order" (:6-10) but omits the Last.fm popularity tier and exploration dial that `AddLastFMStationView.swift:84-103` offers.
- Add `@State private var exploration: Double` (initialised from `config.exploration` in the `.lastFM` init branch; unused otherwise) and an `isLastFM` flag.
- In the `DisclosureGroup`, for Last.fm add the same `Picker("Popularity", selection: $query.popularity)` (popularity is inside `FacetedQuery`, so it already flows through `updateQuery` — the gap was purely UI) and the Comfort↔Explore `Slider` copied from AddLastFMStationView:93-103.
- Saving exploration needs a manager setter that doesn't exist — ship 0e together with Step 2's `applyUpdate`, or as an interim add `StationManager.updateExploration(_ id:, to:)` (mutate `.lastFM` config via `LastFMStationConfig.clampExploration`, persist, return station).
**Test:** StationManagerTests: `updateExploration` clamps to [0,1], preserves station+config id, no-ops on non-Last.fm kinds.

---

## Step 1 — HTTP layer refactor: `handleJSONPost` extraction + preflight Set

Goal: zero behavior change; collapse the five copy-pasted ~35-line POST blocks (`RadioBroadcaster.swift:1656, :1697, :1733, :1768` + `/auth` at :1634) and the six per-connection handler closures (:1566-1604) into one seam that new routes plug into with one switch case.

### 1.1 Path registry
```swift
/// Every JSON POST route. Single source of truth for the OPTIONS
/// preflight AND the POST dispatch — a path added here gets both.
nonisolated static let jsonPostPaths: Set<String> = [
    "/auth", "/like", "/skip", "/next", "/boost", "/unlike"
    // Steps 2-8 append: /stations/list, /stations/create, /stations/update,
    // /stations/delete, /stations/start, /stations/stop,
    // /policy/get, /policy/set, /taste, /exclusions
]
```
Replace the literal OPTIONS chain at :1617 with `if method == "OPTIONS" && Self.jsonPostPaths.contains(path)`.

### 1.2 One dispatch closure + MainActor router
In `routeIncoming`, replace the six `@Sendable` handler closures with one:
```swift
let jsonRoute: @Sendable (String, Data) async -> (Int, Data) = { [weak self] path, body in
    await self?.performJSONRoute(path: path, body: body)
        ?? (500, Data("{\"status\":\"error\",\"message\":\"no broadcaster\"}".utf8))
}
```
and one generic block replacing the five copies:
```swift
if method == "POST", Self.jsonPostPaths.contains(path) {
    let contentLength = Self.contentLength(from: headerBytes) ?? 0
    let body = await Self.readBody(
        connection: connection,
        alreadyRead: Self.bodyBytes(after: headerBytes),
        expected: contentLength
    )
    let (status, payload) = await jsonRoute(path, body)
    var headers = Self.corsHeaders()
    headers["Content-Type"] = "application/json"
    _ = await Self.send(data: Self.buildHTTPResponse(status: status, headers: headers, body: payload), on: connection)
    connection.cancel()
    return
}
```
This also fixes the "six closures allocated per connection even for GET /now.json" cost.

### 1.3 `performJSONRoute` (new, `@MainActor` method on RadioBroadcaster)
```swift
func performJSONRoute(path: String, body: Data) async -> (Int, Data) {
    let dec = JSONDecoder()
    switch path {
    case "/auth":
        return await performAuthAsync(token: (try? dec.decode(AuthRequest.self, from: body))?.token)
    case "/like":
        guard let req = try? dec.decode(LikeRequest.self, from: body) else { return Self.badRequest() }
        if let entry = req.entry, let sid = UUID(uuidString: req.station) {
            return await performRetroLikeAsync(stationID: sid, entryID: entry, token: req.token)
        }
        guard let sid = UUID(uuidString: req.station) else { return Self.badRequest() }
        return await performLikeAsync(stationID: sid, token: req.token)
    // /skip, /next, /boost, /unlike identical shape …
    default:
        return (404, Data("{\"status\":\"error\",\"message\":\"unknown route\"}".utf8))
    }
}
```
with `nonisolated static func badRequest() -> (Int, Data)` for the shared 400 body. Preserve the exact existing per-route semantics (retro-like split, UUID-parse 400s) — read each old block carefully while porting; the retro-like branch lives inside the current `/like` block (:1656-1692).

**Tests:** the entire existing action-endpoint suite (`testPostNextOverSocketWithCoalescedBody`, `testPostLikeOverSocketWithCoalescedBody`, `testOptionsLikeReturnsCORSHeaders`, `testActionsRejectGuestsWith403`, `testPostWithoutTokenOverSocketReturns403`, retro-like in `testTimelineRingUpcomingAndRetroLike`) is the regression net — no new tests required, all must stay green. Add one: OPTIONS against a path NOT in the set still 404s.

---

## Step 2 — StationManager additions + catalogue closure seam + `/stations/list` + `/vocab`

### 2.1 StationManager (`RatbatCore/Radio/StationManager.swift`)
New public surface (all `@MainActor`, all persist synchronously like existing mutations):
```swift
public func station(id: Station.ID) -> Station? { stations.first { $0.id == id } }

public enum StationEditError: Error, Equatable {
    case unknownStation
    case kindHasNoQuery         // playlist (and later libraryRadio) + query edit
    case emptyGenreTags         // validation moved down from the SwiftUI Add sheets
    case wrongKind              // sort on non-Bandcamp, exploration on non-Last.fm
}

/// Everything the edit surfaces (desktop sheet AND web) can change, in one
/// atomic mutation + single persist. nil = leave alone.
public struct StationUpdate: Sendable {
    public var name: String?
    public var query: FacetedQuery?
    public var sort: BandcampClient.Sort?      // #if os(macOS)
    public var exploration: Double?
}

@discardableResult
public func applyUpdate(_ id: Station.ID, _ update: StationUpdate) throws -> Station
```
`applyUpdate` behavior: resolve index (else `.unknownStation`); if `update.query != nil` validate `!genreTags.isEmpty` (else `.emptyGenreTags`) and reject playlist kind (`.kindHasNoQuery`); rename via the existing trimmed/uniquify logic firing `slugDidChange` (0d); mutate configs in place exactly as `updateQuery` does today (preserving station id AND config id — the 225bb06 invariant); clamp exploration via `LastFMStationConfig.clampExploration`; one `persist()` at the end; return the updated station.

Also add throwing create wrappers that enforce the ≥1-tag rule the Add sheets currently gate in SwiftUI:
```swift
@discardableResult public func createValidated(_ kind: Station.Kind, name: String?) throws -> Station
```
switching on kind to reuse `createNTS`/`createLastFM`/`createBandcamp` (name falls back to `query.suggestedName`, mirroring the sheets). Keep the old non-throwing creators for source compatibility; refactor `EditStationView.save()` (:151-175) to call `applyUpdate` so desktop and web share one mutation path (this is where 0e's exploration save lands).

**Temporal-tag normalization (faceted design doc :218, decided here):** add
```swift
extension FacetedQuery {
    /// Move "1990s"-style decade tags out of genreTags into yearMin/yearMax.
    func normalizingTemporalTags() -> FacetedQuery
}
```
Regex `^(19|20)\d0s$`; strips matching tags, sets `yearMin = min(existing, decadeStart)` / `yearMax = max(existing, decadeEnd)`. Apply in `createValidated`/`applyUpdate` **for `.nts` and `.bandcamp` kinds only** — Last.fm keeps decade tags verbatim because its palette ships them deliberately as genuine Last.fm tags (`StationTagPalette.swift:29-42`, "the decade tags Last.fm's users actually apply as genres"). Document that asymmetry in the function comment.

**Tests (StationManagerTests.swift + StationQueryEditingTests.swift):** `station(id:)`; `applyUpdate` happy path preserves both ids; each error case; rename-inside-update fires `slugDidChange` and uniquifies; exploration clamp; temporal normalization per kind; `createValidated` throws on empty tags.

### 2.2 Catalogue closure seam (RadioBroadcaster + RootView)
Per the settled decision — closures, not a StationManager handle, mirroring `selectionPolicyProvider` (:714). In `RadioBroadcaster.swift`:
```swift
/// Injected catalogue capabilities. The broadcaster deliberately does not
/// hold StationManager (see the comment at stationNames) — RootView wires
/// these at storage-attach time, same idiom as selectionPolicyProvider.
public struct StationCatalogue {
    public var list:   @MainActor () -> [Station]
    public var create: @MainActor (Station.Kind, String?) throws -> Station
    public var update: @MainActor (Station.ID, StationManager.StationUpdate) throws -> Station
    public var delete: @MainActor (Station.ID) -> Bool     // false = unknown id
    public init(…)
}
private var catalogue: StationCatalogue?
public func installCatalogue(_ c: StationCatalogue) { catalogue = c }
```
Wire in `RootView.swift` inside the `.task(id: ReloadKey…)` at :185, immediately after `stations.setStorage(root: folder)` / before `registerStations`:
```swift
radio.installCatalogue(StationCatalogue(
    list:   { stations.stations },
    create: { kind, name in try stations.createValidated(kind, name: name) },
    update: { id, u in try stations.applyUpdate(id, u) },
    delete: { id in
        guard stations.station(id: id) != nil else { return false }
        stations.delete(id); return true
    }
))
```
Desktop reflection is free: every mutation goes through `StationManager` → `@Published stations` → `.onChange(of: stations.stations)` at :242-244 → `registerStations`. Handlers answer `503 {"status":"error","message":"catalogue unavailable"}` when `catalogue == nil` (no music folder chosen yet).

### 2.3 `POST /stations/list` (owner-gated) — the read half
Add `"/stations/list"` to `jsonPostPaths`; case in `performJSONRoute` decoding `AuthRequest` (token only) → `performStationsListAsync(token:)`:
1. `ownerGate(token)` → 403.
2. `catalogue?.list()` else 503.
3. Encode `[StationPayload]` (below) with `broadcasting`/`listeners` from `broadcasting`/`listenerCount`, `autoStart` from `preferences.isAutoStart(slug:)`.
Response: `200 {"stations":[…]}`, sorted by name (match `buildNowPayload`).

**`StationPayload` — hand-written Encodable** (new section beside `NowStation` ~:3080), every key always present, explicit nulls, `.sortedKeys` encoder — the wire-shape rules `/now.json` and `/history` already follow:
```json
{
  "id": "UUID", "name": "…", "slug": "…",
  "kind": "playlist" | "nts" | "lastfm" | "bandcamp" | "libraryRadio",
  "broadcasting": false, "listeners": 0,
  "streamURL": "/stream/{slug}.aac" | null,      // null when idle
  "autoStart": false,
  "trackCount": 132 | null,                       // playlist only
  "query": { FacetedQueryPayload } | null,        // generative kinds only
  "shufflePool": true | null,
  "exploration": 0.25 | null,                     // lastfm (+ libraryRadio)
  "sort": "date" | "pop" | null,                  // bandcamp
  "seedCount": 8 | null                           // libraryRadio (Step 9)
}
```
**Scrubbing rules (the leak decision, enforced in the encoder, not the caller):** `.playlist(queue:)` projects to `kind:"playlist", trackCount: queue.count` and nothing else — no `Track.url`, `fileSize`, `dateAdded`, no absolute path of any kind may appear in this payload. `FacetedQueryPayload` mirrors `FacetedQuery`'s pinned CodingKeys exactly (`FacetedQuery.swift:66-70`: `genreTags, yearMin, yearMax, regions, tagMatch, popularity, excludeOwnedLibrary, excludedArtists`), with `excludedArtists` as a **sorted** array (Set → deterministic wire). `excludedArtists` is fine here because the endpoint is owner-gated (settled decision).

**Tests:** raw-socket guest → `403 Forbidden`; owner with one playlist + one lastfm station → assert payload contains `"trackCount"`, does NOT contain `"file://"`, `"fileSize"`, or the fixture path; idle station appears with `"broadcasting":false, "streamURL":null`. Add a `WireConsistencyTests` case pinning that every `StationPayload` key is present on every kind.

### 2.4 `GET /vocab` (public, no auth — nothing sensitive)
Vocabulary source of truth so web forms don't duplicate Swift constants. New block in `routeIncoming` next to `/now.json` (:1864), same header shape + `"Cache-Control": "public, max-age=3600"`:
```json
{
  "palettes": { "nts": […], "lastfm": […], "bandcamp": […] },   // StationTagPalette.nts/.lastFM/.bandcamp
  "tagMatch": ["any", "all"],
  "popularity": ["hits", "middle", "deepCuts"],
  "bandcampSort": ["date", "pop"],
  "kinds": ["nts", "lastfm", "bandcamp", "libraryRadio"],        // creatable-over-web kinds
  "regions": ["AD", "AE", …]                                     // ISO alpha-2 codes
}
```
Regions: serve codes only from `Locale.Region.isoRegions` (the same source `FacetedQueryEditor.swift:197` uses); the web localizes names with `Intl.DisplayNames`. Note: `StationTagPalette` is `#if os(macOS)` (StationTagPalette.swift:1) — the broadcaster's HTTP layer is macOS-only in practice, so reference it inside the existing `#if os(macOS)` payload-builder region; the non-macOS branch returns an empty-palette body like `buildHistoryPayload` does.
**Test:** `GET /vocab` returns 200, contains `"deepCuts"` and every palette entry count matches the Swift arrays.

---

## Step 3 — Station CRUD writes + start/stop

Add to `jsonPostPaths` and `performJSONRoute`: `/stations/create`, `/stations/update`, `/stations/delete`, `/stations/start`, `/stations/stop`. All owner-gated first line, all through the catalogue seam. **Never route to `stopAll()`** — it cancels the listener and tunnel the next request needs (:1163, :1273).

### Request/response shapes
**`POST /stations/create`** — body:
```json
{ "token": "…", "kind": "nts"|"lastfm"|"bandcamp"|"libraryRadio",
  "name": "…"|null, "query": { FacetedQueryPayload }, 
  "sort": "date"|"pop"|null, "exploration": 0.25|null, "shufflePool": true|null }
```
Handler `performStationCreateAsync`: ownerGate → decode into a `StationCreateRequest` (Decodable mirror of the payload; unknown `kind` string → 422 `unknown kind`; `"playlist"` → 422 `playlist stations are created on the desktop`) → build the config (`NTSStationConfig`/`LastFMStationConfig`/`BandcampStationConfig`, fresh `UUID`, name fallback `query.suggestedName`) → for `lastfm`, guard `!preferences.lastFMAPIKey.isEmpty` (BroadcastPreferences.swift:79-80) else 422 `Last.fm API key not configured` (the same gate `AddLastFMStationView` enforces at :126-131) → `try catalogue.create(kind, name)` mapping `StationEditError.emptyGenreTags` → 422 → **`201`** `{"station": StationPayload}`. Name collisions are NOT an error: `uniquifyName` bumps to "(2)" exactly like the desktop; the returned payload carries the actual name/slug.

**`POST /stations/update`** — body:
```json
{ "token": "…", "station": "UUID", "applyNow": false,
  "name": "…"|absent, "query": {…}|absent, "sort": "…"|absent, "exploration": 0.3|absent }
```
Handler `performStationUpdateAsync`: ownerGate → UUID parse else 400 → build `StationUpdate` from present fields → `try catalogue.update(id, update)`; map errors: `.unknownStation`→404, `.kindHasNoQuery`→409 `{"message":"playlist stations have no query"}`, `.emptyGenreTags`→422, `.wrongKind`→409. Then the settled applyNow semantics — **persist first, restart second** (the EditStationView:144-175 crash-ordering rule, already satisfied because `applyUpdate` persisted):
```swift
var restarted = false
if req.applyNow, isBroadcasting(stationID: updated.id) {
    await restartBroadcast(station: updated)   // :1069 — forgetLive:false, resume-set safe
    restarted = true
}
return (200, encode(["station": payload(updated), "restarted": restarted]))
```
`applyNow:false` on a live station saves config only; the pipeline picks it up at its next restart (same as desktop "Save" while off-air). Response includes `"restarted"` so the web can show the desktop's "stops the track that is playing" honesty *before* sending `applyNow:true`.

**`POST /stations/delete`** — `{ "token", "station": "UUID" }`. Name-confirmation is client-side only (settled). Handler: ownerGate → parse → if broadcasting, `stopBroadcast(stationID: id)` first (mirrors PlaylistsSidebarView delete, which stops before deleting) → `catalogue.delete(id)` → `200 {"status":"deleted"}` or 404. Per-station stop never tears the listener down (`tearDownIfEmpty` defaults false, :1120) — safe.

**`POST /stations/start`** — `{ "token", "station" }`. ownerGate → resolve via `catalogue.list()` (NOT `pipelines` — the station is idle) → 404 unknown → `await startBroadcast(station:)` → success = `broadcasting.contains(id)` → `200 {"status":"started"}`; already live → `200 {"status":"already-live"}` (idempotent, matches `startBroadcast`'s guard); failure → `500 {"status":"error","message": self.error ?? "start failed"}`. Also `preferences.rememberLive` happens inside startBroadcast already — a web-started station survives a deploy via the `lastLiveSlugs` union (RootView:219-233).

**`POST /stations/stop`** — `{ "token", "station" }`. ownerGate → `stopBroadcast(stationID:)` (the public one, forgetLive:true — a deliberate owner stop must not resume at next launch) → `200 {"status":"stopped"}`, idempotent even when idle.

### Tests (RadioBroadcasterTests raw-socket pattern)
- create: guest 403; owner NTS create → `201 Created` + station visible in a follow-up `/stations/list`; lastfm create without API key → 422; empty tags → 422; kind `"playlist"` → 422.
- update: `applyNow:false` on a live playlist station leaves `currentItemByStation` untouched; `applyNow:true` restarts (station still in `broadcasting` after; reuse the fixture-track + sleep pattern of `testTimelineRingUpcomingAndRetroLike`); playlist+query → `409 Conflict`; unknown UUID → 404.
- delete: live station → stopped AND removed; listener still answers `/now.json` (extends `testStoppingTheLastStationKeepsTheEndpointServing`, :609).
- start/stop: full cycle over the socket against a playlist fixture station registered via an installed `StationCatalogue` backed by a real `StationManager` with temp storage.
- OPTIONS preflight for each new path (mirror `testOptionsLikeReturnsCORSHeaders`).
- **StationManager-side integration**: install catalogue closures over a `StationManager` with temp `setStorage` root; create via HTTP; assert `.ratbat-stations.json` on disk contains the station (persistence round-trip proof, pattern from StationManagerTests:104).

---

## Step 4 — SSE: named events, push on start/stop and station-list change

`RadioBroadcaster.swift:2044-2092`.

### 4.1 Named frames, back-compat
```swift
nonisolated static func sseEvent(_ json: Data, name: String? = nil) -> Data {
    var out = Data()
    if let name { out.append(Data("event: \(name)\n".utf8)) }
    out.append(Data("data: ".utf8)); out.append(json); out.append(Data("\n\n".utf8))
    return out
}
private func pushSSE(event: String? = nil) { … Self.sseEvent(buildNowPayload(), name: event) … }
```
Existing five call sites (:1322, :1388, :1417, :2027, :2038) stay unnamed → an `EventSource.onmessage` client keeps working unchanged (back-compat contract: unnamed = now-snapshot). Named events fire `addEventListener("stations")` only.

### 4.2 New push points
- End of `startBroadcast` (after the pipeline is registered, ~:1049): `pushSSE(event: "stations")`.
- End of the private `stopBroadcast(stationID:forgetLive:tearDownIfEmpty:)` (after pipeline removal, ~:1150): `pushSSE(event: "stations")`. This covers stop, restart, ran-dry, and delete paths in one place.
- `registerStations` (:1190): before `objectWillChange.send()`, detect a catalogue change (`stationNames` snapshot before/after differs in keys or values) → `pushSSE(event: "stations")`. This is how a *desktop* create/rename/delete reaches web clients.
**Privacy note (write in a comment):** `/events` is public; the `stations` event carries the same public `now.json` body — it is a *nudge*, never the owner catalogue. Owner clients react by re-POSTing `/stations/list`.

**Tests:** unit — `sseEvent(name:)` framing (`event: stations\ndata: {...}\n\n`), extend `testSSEEventFraming` (:1284); integration — subscribe `/events` raw (pattern `testEventsEndpointSendsSSEHeaders` :1293), start a second station, assert the stream contains `event: stations` within timeout; stop it, assert a second one.

---

## Step 5 — `GET /health` (public)

New block in `routeIncoming` beside `/now.json`. Reads the heartbeat table shipped in `adeecbb` (`HistoryStore.recordHeartbeat/heartbeats/liveness/offAirGaps`, HistoryStore.swift:787-849; broadcaster writes rows every `heartbeatInterval` per live station, RadioBroadcaster.swift:187-208).

`buildHealthPayload() async -> Data` (macOS section, near `buildNowPayload`):
```json
{ "status": "ok", "now": 1755864000.0,
  "broadcastingCount": 2,
  "stations": [ { "id": "…", "slug": "…", "name": "…", "broadcasting": true,
      "listeners": 1, "liveness": "onAirAndPlaying"|"onAirButQuiet"|"offAir",
      "offAirGaps": [ {"start": 1755820000.0, "end": 1755823600.0} ] } ] }
```
- `liveness` = `history.liveness(station:from: now-10min, to: now)`.
- `offAirGaps` = `history.offAirGaps(...)` over the last 24 h.
- Station set = currently broadcasting ∪ stations with heartbeats in the 24 h window (those were public on `/now.json` while live — no new leak; idle-forever stations never appear). No auth, same posture comment as `/now.json` :1860-1863.
- No history store → `{"status":"degraded", …}` with empty stations.
Also note in the plan/PR description: `scripts/verify-listening.sh` gains one `curl -sf $URL/health` assertion so a deploy with a dead control plane can't go green (the deploy-verification gap the hardening brief calls out).

**Tests:** raw `GET /health` on a live fixture station → 200, contains `"liveness"`; broadcaster without history → `"degraded"`.

---

## Step 6 — Selection policy over HTTP: `/policy/get`, `/policy/set` (owner-gated, global per settled scope)

The dial ships fully wired and inert (`BroadcastPreferences.selectionPolicy`, BroadcastPreferences.swift:155-176; re-read live per refill via `selectionPolicyProvider()` :714 — **no restart needed, no revision tick**).

- **`POST /policy/get`** `{token}` → `200 {"newMusicShare": null|0.4, "excludeMixSets": false, "mixSetMinimumDuration": 1200}`.
- **`POST /policy/set`** — must distinguish *absent* (leave alone) from *explicit null* (dial off, ≠ 0.0 which is an active reorder — the sentinel comment at BroadcastPreferences.swift:88-95):
```swift
struct PolicySetRequest: Decodable {
    let token: String?
    let newMusicShare: Double??   // nil = absent, .some(nil) = explicit null
    let excludeMixSets: Bool?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        newMusicShare = c.contains(.newMusicShare)
            ? .some(try c.decodeIfPresent(Double.self, forKey: .newMusicShare)) : nil
        excludeMixSets = try c.decodeIfPresent(Bool.self, forKey: .excludeMixSets)
    }
}
```
Handler: ownerGate → read `preferences.selectionPolicy`, overlay present fields, assign back (the setter clamps through `SelectionPolicy`'s init) → return the resulting policy (same shape as get). Takes effect at each station's next pool refill — say so in the web UI copy, and include the SelectionPolicy.swift:76-83 honesty ("new" = artist not in your library) in the doc for the web step.

**Tests:** raw-socket get/set round-trip; unit test on `PolicySetRequest` decoding all three states of `newMusicShare`; set with only `excludeMixSets` leaves the dial untouched.

---

## Step 7 — Transparency: `/taste` and `/exclusions`

### `POST /taste` (owner-gated)
`{token}` → `performTasteAsync`. Sources: `tasteProfile.currentSnapshot()` (TasteProfile.swift:91 — `libraryArtists`/`libraryTags` dictionaries, scores [0,1]) + per-station signal counts from HistoryStore.
New HistoryStore method (one SQL round trip per station):
```swift
public struct SignalCounts: Sendable { public let plays, saves, boosts, skips: Int }
public func signalCounts(forStation station: UUID) throws -> SignalCounts
// SELECT COUNT(*), SUM(saved), SUM(boosted_at IS NOT NULL), SUM(skipped_at IS NOT NULL) …
```
(match actual column names against the migrations at HistoryStore.swift:886/1016/1025 while implementing).
Response:
```json
{ "libraryArtists": [ {"artist": "…", "score": 1.0}, … ],      // top 10 by score
  "libraryTags":    [ {"tag": "…", "score": 0.8}, … ],
  "stations": [ { "id": "…", "name": "…",
      "topAffinityArtists": ["…"],                              // topAffinityArtists(forStation:limit:5), :487
      "counts": {"plays": 214, "saves": 12, "boosts": 3, "skips": 5} } ] }
```
Stations enumerated via `catalogue.list()` (idle included — owner context). This is the taste-intelligence doc's Phase-2 "Taste profile transparency tab" (:141), as JSON.

### `POST /exclusions` — "why this track" (owner-gated)
`{token, "station": "UUID"|null, "limit": 100}` → straight map of `history.exclusions(stationID:limit:)` (HistoryStore.swift:626; struct fields at :48-80):
```json
{ "exclusions": [ { "id": 1, "stationID": "…", "artist": "…", "title": "…",
    "arm": "duration"|"title", "matchedText": "…"|null,
    "durationSeconds": 3720.0|null, "durationSource": "…"|null,
    "sourceKind": "bandcamp", "sourceURL": "…"|null,
    "enforced": false, "everEnforced": false, "enforcedCount": 0, "hitCount": 3,
    "firstExcludedAt": 1755…, "lastExcludedAt": 1755… } ] }
```
`enforced:false` rows are the shadow log — the web panel's "what the mix-set filter *would* remove", the exact preview the toggle's ship-off design intended (SelectionPlanner comment).
**Tests:** seed exclusions via `recordExclusions` on a temp store (pattern: SelectionExclusionLogTests), fetch over the socket, assert shape + station filter; guest 403 for both endpoints.

---

## Step 8 — Boost as steering (signal-model doc §3, the unbuilt step 2)

Boost today stamps `boosted_at` and waits for a natural refill (`performBoostAsync` :2692-2723). Finish the design: **seed override + debounced refill**, pool-only ("stations mid-track finish the track").

### 8.1 Controller seam (`RatbatCore/Radio/LastFM/LastFMStationController.swift`)
- New init param, same idiom as `selectionPolicy` (:135): `seedOverride: @Sendable () async -> [String] = { [] }`, stored.
- New state `private var pendingReseed = false` and entry point:
```swift
public func requestReseed() { pendingReseed = true }
```
- In `nextTrack()` (:144), after `reapplyPolicyIfChanged()`:
```swift
if pendingReseed { pendingReseed = false; try await refillPool() }
```
- In `refillPool()` stage 1b (:305): 
```swift
let overrides = await seedOverride()
var seedArtists = overrides
for a in (try? await history.topAffinityArtists(forStation: config.id, limit: 3)) ?? []
    where !seedArtists.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) {
    seedArtists.append(a)
}
seedArtists = Array(seedArtists.prefix(4))
```
Overrides go to the *front* of the expansion queue (the doc's exact wording); interaction with `topAffinityArtists` is self-healing — the boosted artist earns weight-10 rank there (:487-501), so the override is a fast path, not a fork.

### 8.2 Source plumbing (`RatbatCore/Radio/TrackSource.swift` + wrappers)
```swift
public protocol TrackSource: Actor {
    func nextURL() async throws -> TrackSourceItem?
    func noteSteeringChanged() async          // new
}
public extension TrackSource { func noteSteeringChanged() async {} }  // default no-op
```
`LastFMSource.noteSteeringChanged()` → `await controller.requestReseed()`. NTS / Bandcamp / Playlist keep the no-op — NTS pools are show-based and Bandcamp has no similar-artist API; boost remains rating-only there in v1 (document in the protocol comment).

### 8.3 Broadcaster (`RadioBroadcaster.swift`)
- State: `private var boostSeedOverrides: [Station.ID: [String]]` (most-recent-first, cap 3, case-insensitive dedup) and `private var boostRefillTasks: [Station.ID: Task<Void, Never>]`.
- Provider, consume-once (so an un-debounced natural refill also steers exactly once):
```swift
private func seedOverrideProvider(stationID: Station.ID) -> @Sendable () async -> [String] {
    { [weak self] in await MainActor.run {
        guard let self else { return [] }
        return self.boostSeedOverrides.removeValue(forKey: stationID) ?? []
    } }
}
```
passed into `LastFMStationController` in `makeLastFMSource` (:864-871).
- Debounce constant + schedule (doc :103 "one scheduled refill per station per few minutes"):
```swift
nonisolated static let boostRefillDebounce: TimeInterval = 120
```
- In `performBoostAsync`, after the successful `markBoosted` and before returning 200: record the artist into `boostSeedOverrides[stationID]`; if `boostRefillTasks[stationID] == nil`, schedule a Task that sleeps `boostRefillDebounce`, clears its slot, then `await pipelines[stationID]?.source.noteSteeringChanged()`. Boosts inside the window fold into the pending task (they only append to the override list). Update the now-stale ":2687-2692 no refill is forced" comment.
- Make the debounce testable: follow the `listenerRebindDelay(forAttempt:)` precedent — an internal `var boostRefillDebounceOverride: TimeInterval?` consulted first, settable from tests.

**Tests:**
- LastFMStationController unit (stub `LastFMClient` recording calls — pattern from existing controller tests): seedOverride `["X"]` → refill calls `similarArtists(to:"X")` before affinity seeds; `requestReseed` forces refill mid-pool.
- Broadcaster: with a recording stub `TrackSource`, boost twice within the window with `boostRefillDebounceOverride = 0.2` → exactly one `noteSteeringChanged` call; `boostSeedOverrides` drained after provider call (consume-once).
- Existing `testBoostAndUnlikeOnOwnedTrack` (:1170) stays green.

---

## Step 9 — Library Radio station kind (signal-model doc §4)

### 9.1 Model
New file `RatbatCore/Radio/LibraryRadio/LibraryRadioStationConfig.swift` (per doc :78-86, plus id/name to match sibling configs):
```swift
public struct LibraryRadioStationConfig: Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var exploration: Double        // default 0.5, clamped like LastFM
    public var excludeOwnedLibrary: Bool  // default true — discovery by default
    public var seedCount: Int             // default 8, clamp 1…16
    public var shufflePool: Bool          // default true
}
```
Pin explicit CodingKeys (the FacetedQuery.swift:60-70 rationale — the file is multi-machine).
`Station.swift`: add `case libraryRadio(config: LibraryRadioStationConfig)` — **not** platform-gated (avoid re-creating the `.bandcamp`-on-iOS drop problem), plus `libraryRadioConfig` accessor and `static func fromLibraryRadio(_:)` reusing `config.id` as station id (the history-dedup invariant).

### 9.2 StationStore forward-compat — exact behavior, stated
`StationStore.currentVersion` **stays 1 — do not bump** (a bump makes `setStorage` wipe the whole list on old builds, StationManager.swift:46-53). With the envelope unchanged, an **older build** reading a file containing `{"kind":{"libraryRadio":{"config":{…}}}}`:
- **Read: safe.** Per-entry fail-open decode (`StationStore.swift:80-95`) re-serializes each entry individually; the synthesized `Station.Kind` decoder throws on the unknown `libraryRadio` key, the entry is logged and skipped, every other station loads. The file on disk is untouched by reading.
- **Write-back: lossy.** If that older build then performs ANY station mutation, `persist()` writes its reduced in-memory list — silently dropping the libraryRadio entries from the shared file. This is exactly the accepted single-writer posture: the Mini is authoritative, the MacBook reflects read-only. **Action items:** (1) add a paragraph to `docs/mac-mini-setup.md` (the station-creation warning at :169): "update all machines before creating Library Radio stations; an old build that *edits* stations will drop kinds it doesn't know"; (2) StationStoreTests: pin the libraryRadio JSON wire shape with a round-trip test AND extend `testLoadSkipsUndecodableStationEntries` (:99) with a synthetic unknown-kind entry proving siblings survive (the mechanism the old build will rely on).

### 9.3 Controller + source
New `RatbatCore/Radio/LibraryRadio/LibraryRadioStationController.swift` — actor modeled directly on `LastFMStationController` (same `ResolvedTrack`/`Error` shapes, same nextTrack retry budgets), differing only in `refillPool` stage 1: **seeds derive per refill from the live profile** —
1. `let snap = await tasteProfile.currentSnapshot()`; top `seedCount/2` tags from `snap.libraryTags`.
2. Top boosted/saved artists: `history.topAffinityArtists(forStation: config.id, limit: seedCount/2)` (weight table already ranks boost×10 > save×3 > plays).
3. Fetch `client.topTracks(forTag:)` per seed tag and `similarArtists`/`topTracksForArtist` per seed artist (reusing the stage-1b shape at LastFMStationController:296-331).
4. Then the standard shared stages: `FacetedPipeline.applyExclusions` (honoring `excludeOwnedLibrary`), taste scoring with wildcard fraction widened by `exploration` (copy the LastFM widening), `SelectionPlanner.plan` with `selectionPolicy` + exclusion audit rows (`sourceKind: "libraryRadio"`). No tag-mode/era/region stages — there are no facets.
Wire it for steering from birth: accept the same `seedOverride` closure (Step 8).
New `LibraryRadioSource.swift` — verbatim copy of `LastFMSource` shape (:11-45), `origin: .lastFM` (tracks resolve through the same YouTube path; adding a new `TrackOrigin` case would ripple the wire — keep `.lastFM` in v1 and note it).

### 9.4 Broadcaster + manager + desktop + web
- `RadioBroadcaster.startBroadcast` kind switch (:669-690): `case .libraryRadio(let config): makeLibraryRadioSource(config:)` — mirrors `makeLastFMSource` (:797-873): requires `lastFMClientIfAvailable()` (422-equivalent error string when no API key), history, resolver, tasteProfile; passes `selectionPolicyProvider()` + `seedOverrideProvider(stationID:)`.
- Origin mapping at :1348-1351 gains `case .libraryRadio: origin = .lastFM`.
- `StationManager.createValidated` accepts `.libraryRadio` (no tag validation — it has no tags); `applyUpdate` routes `exploration` to it and throws `.kindHasNoQuery` for `query`.
- Desktop: "New Library Radio…" item in the RootView toolbar plus-menu (:335-350) → minimal `AddLibraryRadioStationView` (name field, Comfort↔Explore slider, exclude-library toggle — "one dial, two fields, no tags" per the doc); `EditStationView` gains a `.libraryRadio` init branch (no `FacetedQueryEditor`; dial + toggle only).
- Web: `kind: "libraryRadio"` in `/stations/create`; `StationPayload` emits `seedCount` and `exploration`, `query: null`.

**Tests:** StationKindTests/StationTests round-trip; controller test with stub client + seeded temp HistoryStore asserting seeds come from profile tags + boosted artists and drift after a boost; broadcaster start over the socket (skip when no API key fixture — follow the existing XCTSkip pattern); create-over-HTTP → 201 → start → `/now.json` shows it.

---

## Route map after all steps (final `routeIncoming` order)

1. `OPTIONS` + `jsonPostPaths.contains(path)` → 204 + CORS
2. `POST` + `jsonPostPaths.contains(path)` → `handleJSONPost` → `performJSONRoute`:
   `/auth`, `/like`, `/skip`, `/next`, `/boost`, `/unlike`, `/stations/list`, `/stations/create`, `/stations/update`, `/stations/delete`, `/stations/start`, `/stations/stop`, `/policy/get`, `/policy/set`, `/taste`, `/exclusions`
3. `/history` (exact or `?` — 0b), `/artwork/*`, `/now.json` — unchanged
4. `GET /vocab`, `GET /health` — new public reads
5. `/events` (named + unnamed frames), `/stream.aac` redirect, `/stream/{slug}.aac`, 404

No CORS header/method changes anywhere: POST-only verbs, token in body, paths added to the one preflight Set (settled decision D1/D2 shape).

---

## Documentation to update alongside code
- `docs/mac-mini-setup.md` — single-writer discipline made explicit: "the Mini is the station catalogue's only writer; the MacBook reflects on relaunch / Reload Library"; the library-radio old-build caveat (9.2).
- `README.md` / new `docs/http-api.md` — endpoint table with request/response shapes (this plan's shapes are the spec).
- `scripts/verify-listening.sh` — add the `/health` probe (Step 5).

### Critical Files for Implementation
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/RatbatCore/Radio/RadioBroadcaster.swift
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/RatbatCore/Radio/StationManager.swift
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/RatbatCore/Views/RootView.swift
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/RatbatCore/Radio/LastFM/LastFMStationController.swift
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/RatbatCore/Tests/RadioBroadcasterTests.swift