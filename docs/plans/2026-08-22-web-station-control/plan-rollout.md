# Ratbat Web Station Control — Sequencing, Deployment & Verification Plan

Verified against `ratbat` @ adeecbb and `ratbat.fm` @ 963be6d (the scratchpad clones). All decisions from the approved scope are taken as given; this plan orders them, defines the version-skew contract, and specifies verification.

Absolute paths used below:
- Swift repo: `/private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat` (implementation happens in the user's real checkout, see Phase G0)
- Web repo: `/private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat.fm`

---

## 0. G0 — Git pre-flight (do first, both repos, user's REAL checkouts)

The user's local checkouts are ~60 commits behind origin/main. Do NOT implement in the scratchpad clones — they are throwaway exploration copies.

Per repo (`~/GitHub/org/jonasjohansson/ratbat` and the ratbat.fm checkout; confirm paths with the user):

1. `git status --porcelain` — must be empty. If not: stop, show the user the dirty files, and let them decide (stash vs commit). Do not auto-stash: the Swift repo's working tree may contain Mini-only tweaks (LaunchAgent paths, tokens) worth inspecting.
2. `git fetch origin`
3. `git log --oneline HEAD..origin/main | head -20` — sanity-read what's incoming (expect ~60 commits; confirm adeecbb / 963be6d are among them).
4. `git log --oneline origin/main..HEAD` — must be EMPTY. If local-only commits exist, stop and reconcile with the user (the stale `local-wip` branch precedent says local divergence has happened before).
5. `git switch main && git pull --ff-only` (ff-only so any divergence fails loudly instead of merging).
6. Verify `git rev-parse HEAD` == `git rev-parse origin/main`.
7. Branch per milestone: `git switch -c feat/<milestone>` — never commit to main directly.
8. The Mini deploys from its OWN clone (`docs/mac-mini-setup.md:29-37`). Before each `install.sh` run in later phases: ssh/screen-share to the Mini, repeat steps 1-6 there. A dirty or stale Mini clone is the most likely deploy foot-gun.

---

## 1. Milestones and dependency graph

Each milestone is independently shippable. Web milestones (W*) deploy instantly via GitHub Pages push; server milestones (S*) require a manual `install.sh` on the Mini (which is a brief on-air interruption — batch server milestones into as few deploys as possible; the natural grouping is 3 Mini deploys total: S1, S2+S3, S4).

```
G0 (git pre-flight)
 ├── W1  Client-only wins            (no server dep — ship first, same week)
 └── S1  Server prerequisites+health (Mini deploy #1)
          ├── W2  SSE + on-air strip + status texts (needs S1)
          ├── S2  Station CRUD API + vocab          (needs S1)
          │     └── W3  Station editor panel        (needs S2; SSE from W2 optional, poll fallback works)
          ├── S3  Steering + policy endpoints       (needs S1 only — parallel with S2)
          │     └── W4  Policy controls + boost UX  (needs S3 + W3's owner panel shell)
          ├── S3b Transparency endpoints            (needs S1 only — parallel with S2/S3)
          │     └── W5  Why-this-track + taste page (needs S3b)
          └── S4  Library Radio kind                (needs S2)
                └── W6  Library-radio create form   (needs S4 + W3)
```

Parallelization: W1 ∥ S1. After S1 ships: S2, S3, S3b are mutually independent server tracks (S2+S3+S3b can go in one Mini deploy if built together). W2 ∥ S2. W4/W5 only need the owner-panel shell from W3, not full CRUD.

### W1 — Client-only wins (ratbat.fm only, zero server change)
Small, ship as 3-4 individual pushes:
1. Richer TEXT-ONLY now-playing: render `album`, `durationSeconds` as a progress bar, `origin` badge, `recent[].playedAt` timestamps. All already on the wire (`RadioBroadcaster.swift:3026-3062`), all unused (`js/app.js` grep-verified). NO `artworkURL`/`<img>` per scope.
2. Derive `DISPLAY_DELAY_MS` from `durationSeconds` (replaces hardcoded 10s at `js/app.js:50`).
3. Boot-time passcode validation: on load, if `localStorage.ratbat_key` exists, POST `/auth`; clear key + relock on 403. (`/auth` is side-effect-free, `RadioBroadcaster.swift:1634`.) This also becomes the single "amOwner" signal every later owner UI gates on.
4. History panel: `?offset=` paging (server clamps limit 1-200, `:2969-2977`) + per-station filter using the already-emitted-but-ignored `station`/`stationID` fields. Client-side filter over fetched pages in v1 (no server change).
5. Poll backoff on failure (the no-backoff hammer at `js/app.js:475`) — cheap, and W2's poll-fallback path inherits it.
6. Capability-probe module scaffold (`caps.js` concept inside app.js): a function that GETs `/health`, treats 404 as `capabilities: []`, caches for the page lifetime. Ships now so W2+ are one-line gates.

### S1 — Server prerequisites + /health (Mini deploy #1)
All in `RadioBroadcaster.swift` unless noted. This deploy is safe against the OLD web client (purely additive + bug fixes).
1. **Listener rebind hole** (hard prerequisite for any web-driven stop): fix `scheduleListenerRebind`'s `guard !pipelines.isEmpty` bail (`:1456`) and `startBroadcast`'s `listener == nil`-only rebuild (`:956`) so a failed-but-non-nil listener at zero stations can recover. Add regression XCTest.
2. **autoStartSlugs re-key on rename** (`BroadcastPreferences` + `StationManager.rename`) — today `registerStations` re-keys only the live record (`:1198-1206`).
3. **/history prefix-match tightened** (`:1808`) — exact-match or `==`/`hasPrefix("/history?")` before more routes join the chain.
4. **Status-text table**: add 201/403/409/410/422 to `buildHTTPResponse` (`:2286-2296`).
5. **`handleJSONPost(path:as:handler:)` extraction** collapsing the five copy-pasted POST blocks (`:1656-1804`); OPTIONS allow-list becomes a `Set<String>` (`:1617`). Pure refactor, existing `RadioBroadcasterTests` + `WireConsistencyTests` must stay green.
6. **`GET /health`** — public, unauthenticated, side-effect-free: `{status:"ok", version:"<git short-sha or CFBundleVersion>", capabilities:[...], liveness:"onAirAndPlaying|onAirButQuiet|offAir", offAirGaps:[...]}` from the heartbeat table (`liveness()`/`offAirGaps()`, adeecbb). This is the feature-detection anchor (see §2).
7. **Named SSE events + push on start/stop**: `sseEvent` (`:2085`) gains `event:` lines (`now`, `stations`); add the missing `pushSSE()` in `startBroadcast`/`stopBroadcast`. Backwards-safe: old client doesn't use SSE at all.
8. **Desktop parity fix**: `EditStationView` gains Last.fm popularity + exploration (closing the gap vs `AddLastFMStationView.swift:84-103`); add `StationManager.updateExploration`/`updatePopularity` setters. Do this BEFORE the web editor mirrors the form.
9. **Body-limit measurement + mitigation** (see risk R3): XCTest that round-trips a maximal config through the real socket path; raise/cap limits as measured.

### W2 — SSE + on-air strip (needs S1)
1. `EventSource('/events')` with fallback to the existing poll loop when: `/health` lacks `sse-named-events` capability, `EventSource` errors twice, or the browser lacks it. Listen for named `now` and `stations` events; unnamed legacy frames still handled (old server).
2. On-air strip rendered from `/health` `liveness` + `offAirGaps` — as its own top-level element following the `#history` pattern (own render function; NOT inside the destructively re-rendered `#stations` grid, `app.js:148-281`).
3. Client-side handling for the new status texts (403/409/410/422 message mapping in `sendAction`'s error path).

### S2 — Station CRUD API (Mini deploy #2, can bundle S3/S3b)
1. **Mutation seam**: injected closures on `RadioBroadcaster` — `listStations`, `createStation`, `updateStation`, `deleteStation` — wired in `RootView` next to the existing `selectionPolicyProvider`/`recordPlay` wiring (`RootView.swift:193, 242-244`), hopping to `@MainActor` `StationManager`. Broadcaster never holds `StationManager` (preserves the `:480` ownership comment).
2. **`StationManager` additions**: `station(id:)`, general `update(_:)` covering query/tagMatch/sort/popularity/exploration/excludeOwnedLibrary, with creation-time validation (≥1 tag, API-key presence) MOVED DOWN from the SwiftUI Add sheets into `StationManager` so HTTP and desktop share one validator. Name-collision keeps `uniquifyName` but the HTTP response reports the final name (and 409 where the design says so).
3. **Routes** (all POST, token in body, added to the OPTIONS set): `/stations/list`, `/stations/create`, `/stations/update` (with `applyNow: Bool` → persist first, then optional `restartBroadcast(station:)`), `/stations/delete` (stops broadcast first, mirroring `PlaylistsSidebarView.swift:109-132`), `/stations/start`, `/stations/stop` (per-station only — `stopAll` is never exposed).
4. **Projection**: generative kinds serialize full config; playlist kind projects to `{kind:"playlist", trackCount}`. A serializer-level guarantee (not route-level) so no future route can leak `Track.url`/`fileSize`/`dateAdded`/absolute paths.
5. **`/config/vocab`** (POST, owner-gated or public — public is fine, it's constants): `StationTagPalette` per source, region codes, popularity tiers, sort options, tagMatch values — so web forms don't duplicate Swift constants.
6. `pushSSE()` `stations` event fired from the mutation closures' completion (desktop reflection is free via `@Published` → `.onChange` → `registerStations`).
7. Capabilities gain `stations-crud`, `vocab`.
8. Temporal-tag normalization on decode (`2000s`-style tags → `yearMin/yearMax`) before the web round-trips them (`faceted design:215-221`).

### W3 — Station editor panel (needs S2)
1. Owner panel as a sibling top-level `<aside id="editor">` following the `#history` pattern — own render function, opened via a per-card gear that survives re-render because the panel state lives outside `#stations`.
2. Forms built from `/config/vocab` (tag chips, region select, year inputs, tagMatch/sort/popularity/exploration per kind). Minimal CSS: this repo has zero form primitives today — add a small tokenized form block to `style.css`, no framework.
3. Create (kind picker: NTS/Last.fm/Bandcamp), edit (with an explicit "Apply now — interrupts the current track" checkbox mapping to `applyNow`, mirroring `EditStationView.swift:117-137`'s honesty), delete (type-the-station-name confirmation client-side), start/stop.
4. Entire panel gated on `amOwner && caps.has('stations-crud')` — old server ⇒ panel absent, site works exactly as before.

### S3 — Steering + policy (bundle with S2's deploy if ready)
1. **Boost-as-steering** per `docs/plans/2026-08-04-signal-model-and-library-radio-design.md:70,103`: seed-override entry point on the station-controller protocol (boosted artist to the front of similar-artist expansion) + debounced pool refill (debounce guidance pre-written at design:103). `performBoostAsync` (`:2693-2723`) grows the trigger; `HistoryStore.markBoosted` unchanged.
2. **`/policy/get` + `/policy/set`** (owner-gated POST): global `SelectionPolicy{newMusicShare, excludeMixSets, mixSetMinimumDuration}` — read live per refill already (`:714-717`), so no restart needed. Persists via `BroadcastPreferences` through an injected closure (same seam pattern).
3. Capabilities gain `policy`, `boost-steering`.

### S3b — Transparency endpoints (parallel with S2/S3)
1. **`/why`** (owner-gated POST, `{entryID or historyID}`): serve `selection_exclusions` audit rows (`SelectionPlanner.swift:12-49`, `HistoryStore.exclusions :626`) + the winning track's score components.
2. **`/taste`** (owner-gated POST): top-10 artists/tags, ♥/boost/skip counts from `TasteProfile` (per `taste-intelligence-design.md:141`).
3. Capabilities gain `why`, `taste`.

### W4 — Policy controls + boost UX (needs S3 + W3 panel shell)
newMusicShare slider (with the honest '"new" = you own nothing by this artist' copy from `SelectionPolicy.swift:76-83`), mix-set toggle + min-duration, in the owner panel. Boost button copy updated to reflect steering ("points the radio at this artist").

### W5 — Transparency UI (needs S3b)
"Why this track" expandable on now-playing + history rows (owner-only); taste-profile page as another top-level panel. Text only.

### W6/S4 — Library Radio (last)
1. `Station.Kind.libraryRadio` + `LibraryRadioStationConfig` per `signal-model design:78-92`. **Do NOT bump `StationStore.currentVersion`** — add the kind with the existing per-entry fail-open decode (see risk R2). Old app versions skip-decode the new kind rather than wiping the file.
2. Desktop: "New Library Radio…" menu item; web: the kind appears in W3's create picker gated on capability `library-radio`.
3. It's the ideal first web-created kind: one dial, two fields, no external API key.

---

## 2. Deploy / version-skew contract

Reality: GitHub Pages ships in seconds; the API only changes after a human runs `install.sh` on the Mini (which restarts the radio). Every client/server pairing must work.

**Contract — `/health` capability advertisement:**
- `GET /health` (public, no auth, no side effects) returns `{status, version, capabilities: [string], liveness, offAirGaps}`.
- Capability strings are append-only, never renamed, never removed within v1: `health`, `sse-named-events`, `stations-crud`, `vocab`, `policy`, `boost-steering`, `why`, `taste`, `library-radio`.
- **Client rules**: probe `/health` once per page load, 404 ⇒ empty capability set (pre-S1 server); render zero owner-management UI for absent capabilities; SSE only when `sse-named-events` present, else poll. Never assume an endpoint exists — a 404 from any gated call additionally clears that capability for the session (belt-and-braces against a mid-session Mini rollback).
- **Server rules**: all JSON changes additive (old client ignores unknown keys — hand-written encoders already emit every key always); never repurpose an existing route's response shape; new routes must appear in BOTH the router and the OPTIONS `Set` in the same commit (add an XCTest asserting the two lists match — this is the silent browser-only failure mode).
- **Ordering rule**: for any feature pair, the server half deploys FIRST (web can ship dark, capability-gated, even before the Mini deploy — it simply won't render). This means web PRs can merge freely without coordinating with Mini deploy windows.

**Mini deploy procedure per server milestone**: G0 steps 1-6 on the Mini's clone → `./install.sh` (existing kill/wait/copy/open/verify flow, `install.sh:34-127`) → extended verification (§3).

---

## 3. Verification

### 3.1 Outside-in control-plane check (new script)
New `scripts/verify-control-plane.sh`, called by `install.sh` after `verify-listening.sh` (same outside-in philosophy: through Cloudflare, never localhost — `docs/2026-08-09-listening-hardening.md:32-33`). Runs only when `RATBAT_OWNER_TOKEN` is set (env or `~/.ratbat-owner-token` mode-600 file); otherwise prints SKIPPED so the deploy doesn't go green-by-omission silently — it goes green-with-a-warning.

Sequence (each step a distinct exit code, verdict appended to `~/Library/Logs/ratbat-verify.log` like `verify-listening.sh` does):
1. `GET /health` → 200, `status:ok`, capabilities non-empty. (Exit 2: control plane absent.)
2. `POST /auth` with token → ok. With `token:"wrong-$(date +%s)"` → 403 with the new status text. (Exit 3: auth broken/gate open.)
3. `POST /stations/create` a throwaway Last.fm-or-NTS station named `zz-verify-<epoch>` (NTS avoids needing an API key) → 201, capture id. (Exit 4.)
4. `POST /stations/update` (add a tag, `applyNow:false`) → 200; `POST /stations/list` → station present with the edit, and assert the response contains NO `file://` substring anywhere (projection leak check). (Exit 5.)
5. `POST /stations/delete` with the id → 200; `/stations/list` → gone. (Exit 6.)
6. Never starts the throwaway station — no audible impact; `verify-listening.sh` already covers audio.
7. Trap-based cleanup: on any failure after step 3, attempt delete before exiting, so aborted verifies don't litter the sidebar.

`install.sh` gains exit-code-specific diagnosis lines for these, matching its existing style (`install.sh:94-125`).

### 3.2 XCTest additions (run by existing CI — the only automated gate)
In `RatbatCore/Tests/`, following existing file conventions:
- `RadioBroadcasterTests`: route ↔ OPTIONS-set parity assertion; each new route's happy path + 403 wrong-token + 422 invalid-body; `/history` exact-match regression; status-text table entries.
- New `StationProjectionTests` (WireConsistencyTests style): encode a catalogue containing a playlist station with absolute `file:///Users/...` URLs → assert output contains `trackCount` and zero occurrences of `file://`, `fileSize`, `dateAdded`.
- `StationManagerTests`: new `update(_:)`/`updateExploration`/`updatePopularity`; validation moved down from views; rename re-keys `autoStartSlugs`.
- Listener-rebind regression: stop all pipelines with a poisoned listener, start one, assert listener rebuilds.
- Body-limit test: max-realistic config payload (40 tags × 30 chars, 15 regions, 100 excludedArtists — measure actual encoded size first) through the real read path; assert decode succeeds or a clean 413, never a truncated opaque 400.
- SSE unit: `sseEvent` emits `event: now` / `event: stations` frames; `startBroadcast`/`stopBroadcast` push.
- CI (`.github/workflows/ci.yml`) builds/tests Swift only — no change needed; all the above ride the existing macOS test job. **Web code has no CI**: verification is §3.3/§3.4.

### 3.3 SSE + web UI testing (manual/scripted — no web CI exists)
- SSE outside-in: `curl -N https://radio.jonasjohansson.se/events | head -40` after a station start/stop — assert named `event:` lines arrive. Add as an optional step in `verify-control-plane.sh` (10s timeout, non-fatal: cloudflared buffering quirks shouldn't fail a deploy — see R6).
- Local web dev loop: `python3 -m http.server` in ratbat.fm + `?api=http://localhost:18000` (the existing `resolveAPIBase` override, `app.js:5-18`) against a locally-running dev build — this is the primary pre-push check.
- Optional (not v1-blocking): a Playwright smoke via the webapp-testing tooling run locally — load page, assert grid renders from a stubbed `/now.json`, assert owner panel hidden without capability. Keep out of CI to preserve the no-build-step property.

### 3.4 Manual test script for the user (per milestone, ~5 min each)
Written into the PR description of each milestone. Core sequence after the S2+W3 pair:
1. Phone + laptop both open ratbat.fm. Log in on laptop (lock button).
2. Create "Test FM" (NTS, one tag) from the laptop → appears on the phone within seconds (SSE) and in the Mac app sidebar without relaunch.
3. Edit its tags WITHOUT "apply now" while it's off-air → desktop shows the edit.
4. Start it from the web; confirm audio; stop it from the web; confirm the OTHER station's audio still plays (listener-hole regression, the big one).
5. Delete it — confirm the name-typing gate, confirm it's gone everywhere.
6. Wrong-passcode attempt from a private window → clean 403 message, lock stays locked.
7. Reload with an old cached page (hard-refresh-less) → still works (skew check).
8. MacBook app: relaunch → sees the web-created state (documented single-writer reflection).

---

## 4. Risk register

| # | Risk | Likelihood/Impact | Mitigation |
|---|---|---|---|
| R1 | **Listener-hole lockout**: web stops last station → `scheduleListenerRebind` bails on empty `pipelines` (`:1456`), `startBroadcast` won't rebuild non-nil dead listener (`:956`) → radio permanently unreachable until someone touches the Mini. | Med / High | Fixed in S1 BEFORE any stop route exists (S2). Regression XCTest + manual step 4 in §3.4. `/stations/stop` refuses to exist in a build without the fix (same commit ordering). |
| R2 | **StationStore silent wipe**: `setStorage` treats `versionMismatch` like "no file" (`StationManager.swift:46-53`); with two writers, an old-version app on the MacBook opening the Drive-synced file after a version bump overwrites everything. | Low / Critical | Policy: NO `currentVersion` bump in this entire plan — Library Radio ships as a new kind under v1 with per-entry fail-open decode. Additionally in S1: change `versionMismatch` handling to load-nothing-AND-refuse-to-persist (read-only latch + visible banner) instead of wipe-on-next-write. Document Mini-authoritative single-writer in `docs/mac-mini-setup.md`. |
| R3 | **Body-size limits**: 4096-byte header cap (`:3351-3353`) is fine (headers are small), but `readBody`'s 3s wall clock with connection-cancelling watchdog (`:2161-2181`) can truncate a config payload over a slow tunnel → opaque 400. | Med / Med | Measure first (S1): encode the §3.2 max-config — expected 2-6 KB, likely fine on bytes but the 3s clock is the real risk on cellular-through-Cloudflare. Mitigate: raise body deadline to 10s for owner routes, add explicit `Content-Length` check with clean 413 over 64 KB, and the socket-path XCTest. Web sends `Content-Length` always (fetch does). |
| R4 | **Drive conflict copies**: Mini writes `.ratbat-stations.json` on every web edit; a MacBook app instance pointed at the same folder is a second writer → "conflicted copy" files and lost edits (`docs/mac-mini-setup.md:169`). | Med / Med | Settled decision: Mini-authoritative, no file watching, MacBook reflects on relaunch. Enforce socially + document: README + setup doc get a "the MacBook app is read-only for stations; create/edit via web or on the Mini" section in S2's PR. Optional cheap guard (S2): desktop shows the existing broadcast-settings-changed-style banner if the store file's mtime is newer than last load at persist time, warning before overwriting. |
| R5 | **Passcode compromise blast radius with delete enabled**: one shared, case-insensitive, non-constant-time passcode now guards destruction; no revocation, no audit. | Low / High | Settled: no sessions. Cheap guards shipped in S2: (a) client-side type-the-name delete confirm; (b) server-side audit line per mutating call (timestamp, route, station, ok/denied) to the unified log + a rolling file — so compromise is at least diagnosable; (c) `ownerGate` throttle already exists (`:2389-2401`); extend it so denied WRITE attempts throttle harder (per-route counter). Recovery path is unchanged: rotate in desktop Settings, which invalidates all browsers. Deletion is recoverable socially only — note in the user docs that `.ratbat-stations.json` is Drive-synced, so Drive version history is the undo. |
| R6 | **SSE through cloudflared**: connection caps/buffering — cloudflared holds long-lived connections fine, but Cloudflare may buffer without heartbeats, and browsers cap ~6 SSE connections per host over HTTP/1.1. | Med / Low | Server already sends periodic frames (listener-count pushes); add a `: keepalive` comment frame on a 25s timer in S1 if idle. One `EventSource` per page (single shared connection). Poll fallback (W2) triggers after 2 consecutive `EventSource` errors, so worst case is today's behavior. Verify outside-in in §3.3, non-fatally. |
| R7 | **Deploy skew breaks the public site** (old client vs new server or vice versa). | Med / Med | §2 contract: additive-only JSON, capability gating, 404-tolerant probes, server-first ordering, route/OPTIONS parity test. Manual step 7 in §3.4. |

---

## 5. Suggested execution order (small PRs)

1. G0 both repos (user + Mini clones).
2. W1 as 3-4 tiny ratbat.fm PRs — immediate visible wins, zero risk.
3. S1 branch → PR → CI green → Mini deploy #1 → `verify-listening.sh` green (control-plane script SKIPs, no CRUD yet — but `/health` step asserts).
4. W2 (SSE + strip) once `/health` is live.
5. S2 (+S3, S3b if ready) → Mini deploy #2 → full `verify-control-plane.sh` green through Cloudflare.
6. W3 editor panel → manual test script §3.4 with the user.
7. W4, W5 as the endpoints land.
8. S4 Library Radio → Mini deploy #3 → W6.

### Critical Files for Implementation
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/RatbatCore/Radio/RadioBroadcaster.swift (router, CORS/OPTIONS set, ownerGate, SSE, body limits, /health, all new routes)
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/RatbatCore/Radio/StationManager.swift (new setters, validation moved down, rename re-key, versionMismatch latch)
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/RatbatCore/Views/RootView.swift (closure-seam wiring, desktop reflection via .onChange → registerStations)
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat.fm/js/app.js (capability probe, SSE client, owner panel, all web milestones)
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/install.sh + /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/scripts/verify-listening.sh (deploy hook for the new verify-control-plane.sh)