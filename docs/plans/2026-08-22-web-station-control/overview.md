# Ratbat — Web Station Control: Create/Steer/Edit Stations from ratbat.fm

## Context

Ratbat's broadcaster (Mac Mini, 24/7, Cloudflare tunnel → `radio.jonasjohansson.se`) already ships owner-passcode auth (`POST /auth`), per-track actions (`/like /skip /next /boost /unlike`), `/history`, SSE `/events`, and rich `/now.json`. What's missing is exactly the user's ask: **no station CRUD over HTTP** — stations can only be created/edited in the desktop app. Goal: logged-in web owners can create stations on the fly, edit tags/settings (faceted query, smart-station knobs), steer the radio, and see richer **text-only** track metadata — all reflected in the desktop app — plus steering/transparency/hardening features grounded in the repo's own design docs.

**Two repos** (work happens in the user's real checkouts, currently ~60 commits behind `origin/main` — see G0):
- `~/GitHub/org/jonasjohansson/ratbat` — Swift. The entire HTTP layer is `RatbatCore/Radio/RadioBroadcaster.swift` (3713 lines, hand-rolled HTTP over NWListener, one if-chain router `routeIncoming` ~:1540-1990).
- `~/GitHub/org/jonasjohansson/ratbat.fm` — static site, no build step: `index.html`, `js/app.js` (~625 lines), `css/style.css`.

Full design detail (exact code snippets, payload structs, test lists) was produced by the design workflow and lives in the scratchpad: `plan-server.md`, `plan-client.md`, `plan-rollout.md`, `plan-review.md` at `/private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/`. **First implementation step: copy these four files into `ratbat/docs/plans/2026-08-22-web-station-control/` and commit**, so they survive the session (repo convention: `docs/plans/`).

## Settled decisions (user-approved; do not relitigate)

- **Auth**: keep the shared owner passcode in the JSON body (existing `ownerGate`, `RadioBroadcaster.swift:2389`). Cheap guards only: client validates stored key against `/auth` on boot; delete requires typing the station name client-side. No sessions, no Cloudflare Access.
- **API shape**: POST-only path-verbs, token in body. Station id field is named **`station`** (matches shipped `LikeRequest`). Payloads are **flat** (`{kind, name, query, sort, exploration, shufflePool, excludeOwnedLibrary, autoStart}`), kind strings use synthesized coding-key casing (**`lastFM`**, `nts`, `bandcamp`, `libraryRadio`).
- **Kinds on the web**: generative only (NTS, Last.fm, Bandcamp) + new Library Radio kind. Playlist stations stay desktop-only; `/stations/list` projects them to `{kind:"playlist", trackCount}` — never `Track.url`/`fileSize`/`dateAdded`/absolute paths.
- **Catalogue write access**: injected closure seam wired in `RootView` (mirrors `selectionPolicyProvider`/`recordPlay` idiom). Broadcaster never holds `StationManager`.
- **Edit semantics**: `applyNow: Bool` on update — persist first, then optionally `restartBroadcast(station:)`. Desktop reflection is free: `StationManager` `@Published` → `RootView.onChange` → `registerStations`.
- **Sync**: Mini-authoritative single writer; no file watching. MacBook picks up changes on relaunch/"Reload Library" (document in `docs/mac-mini-setup.md`).
- **Selection dial**: expose the existing **global** `SelectionPolicy` (`newMusicShare` + `excludeMixSets`) — not per-station in v1. `mixSetMinimumDuration` is NOT persistable (`BroadcastPreferences.swift:155-176` drops it) → no web control for it.
- **SSE**: name **all** events (`now`, `stations`, and change the `": heartbeat"` comment at `RadioBroadcaster.swift:1910` to `event: ping\ndata: {}\n\n`). No unnamed-frame back-compat needed — zero EventSource consumers exist today.
- **Capability detection**: `/health` returns `{version, capabilities:[string], …}` as the anchor; client keeps 404-tolerance as belt-and-braces. `vocab.kinds` gates the kind picker (Library Radio only appears when the server supports it).
- **Cut (YAGNI, per cross-review)**: temporal-tag normalization; permalinks; `t.year/t.genre` dead render branches; score-breakdown stub; versionMismatch read-only latch; desktop mtime-conflict banner; server audit log; `updatePopularity` setter (popularity is inside `FacetedQuery`, flows through `updateQuery`); Playwright CI.

## Milestones (each independently shippable)

### G0 — Git pre-flight (user's real checkouts)
Both repos: confirm clean (`git status`), `git pull --ff-only` to `origin/main` (`adeecbb` / `963be6d`). Copy design docs in (see Context). All work branches from updated `main`.

### W1 — Client-only wins (ratbat.fm; zero server dependency, ships day 1)
1. **SSE transport** (`js/app.js`): `EventSource('/events')` with `onmessage` (today's unnamed frames) + `addEventListener` for future `now`/`stations`/`ping`; poll fallback with backoff when SSE fails; visibility-change reconnect.
2. **Richer text meta** in `render()` (~app.js:171-281): album, `origin` badge, duration as text progress (`elapsed / durationSeconds`), `recent[].playedAt` times — all already on the wire, all currently ignored. No artwork `<img>` (user wants text-only).
3. `DISPLAY_DELAY_MS` derived from `durationSeconds` (replace hardcoded 10s at app.js:50).
4. **Boot-time `/auth` validation** of `localStorage['ratbat_key']` (rotation currently leaves lock lying 🔓 until first failed action).
5. Central `apiPost()` wrapper + `friendlyError` map (403/404/409/410/422/503).
6. One "polish" commit: theme-color/manifest mismatch, reduced-motion, 'N listening' tweak.

### S1 — Server prerequisites + /health (Mini deploy #1) — `RadioBroadcaster.swift` unless noted
1. **Status texts**: add 201/403/410/422 to `buildHTTPResponse` (:2286-2296).
2. **`/history` prefix-match** → exact `== "/history" || hasPrefix("/history?")` (:1808).
3. **Empty-pipelines listener hole** (hard prerequisite for web stop): remove `guard !pipelines.isEmpty` from `scheduleListenerRebind` (:1456) + defensive failed-listener recreate in `startBroadcast` (:956).
4. **`handleJSONPost` refactor**: `jsonPostPaths: Set<String>` as single source of truth for OPTIONS preflight (:1617) + POST dispatch; one `performJSONRoute(path:body:)` `@MainActor` router replacing the five copy-pasted POST blocks and six per-connection closures. Zero behavior change.
5. **Body limits** (review G2): raise the 3s `readBody` deadline for `jsonPostPaths` routes, reject > 64KB with 413 + status text. Socket-path test.
6. **`GET /health`** (public): `{status, version, capabilities, uptimeSeconds, broadcastingCount, stations:[{id, name, slug, broadcasting, liveness, lastGap}]}` from the heartbeat table (`HistoryStore.liveness/offAirGaps`, per-station; single most-recent gap only).
7. **SSE naming** (`event: now` / `event: ping` heartbeat) — client already handles both paths.
8. **autoStartSlugs re-key on rename** (`StationManager.slugDidChange` closure, wired in `RootView`); also clear autoStart/lastLive slugs on **delete** (review G3).
9. **Desktop Edit/Add parity** (`EditStationView.swift`): add Last.fm popularity picker (flows through existing `updateQuery`) + exploration slider via interim `StationManager.updateExploration`.

### W2 — Health strip + capability probe (needs S1)
On-air strip (`● on air · 3d 4h · 2 live`, one recent-gap line) rendered from `/health`; `probeCapabilities()` reads `health.capabilities`, gates all later panels. 503 on `/stations/list` = "capable but unavailable", shown, not hidden.

### S2 — Station CRUD API (Mini deploy #2)
- **`StationManager` additions** (`StationManager.swift`): `station(id:)`, general `applyUpdate(id:update:)` preserving station id + config id (the 225bb06 invariant — config id keys HistoryStore dedup/affinity), validation moved down from SwiftUI Add sheets (≥1 tag, API-key presence), setters covering `exploration`, `shufflePool`, `excludeOwnedLibrary` (review G6/G7).
- **Closure seam** in `RadioBroadcaster` + `RootView`: `listStations`, `createStation`, `updateStation`, `deleteStation` closures.
- **Routes** (all owner-gated POST, added to `jsonPostPaths`): `/stations/list`, `/stations/create`, `/stations/update` (with `applyNow`), `/stations/delete`, `/stations/start`, `/stations/stop` (never `stopAll`), `/stations/autostart` (review G4). 410 when UUID parses but station missing; 503 when no music folder.
- **`GET /vocab`** (public, cacheable): `{tags:{nts,lastFM,bandcamp}, tagMatch, popularity, bandcampSort, kinds, regions:[ISO codes]}` from `StationTagPalette` — single source so web forms never duplicate Swift constants.
- **SSE**: `event: stations` pushed on start/stop and any catalogue change (also fixes the latent missing-push-on-start/stop bug).
- **`/health.capabilities`** += `stations`.

### W3 — Station editor panel (needs S2)
- **Panel framework** (`js/panels.js` + `index.html` + CSS tokens): top-level `<aside>` panels copying the `#history` pattern (own render fn — never inside the destructively re-rendered `#stations` grid). Form primitives: inputs, selects, tag chips, focus states, `<dialog>` replacing native `prompt()` for delete-confirm. Dark-mode via existing CSS vars.
- **Stations panel**: full catalogue (incl. idle) with start/stop/auto-start; ⚙/+ affordances on the grid chrome only.
- **Editor form**: create + edit for NTS/Last.fm/Bandcamp from `/vocab`; "Save" vs "Save & restart station" (surfaces `applyNow`); typed-name delete confirm; optimistic UI reconciled by `event: stations`.
- Move history rendering into the panel framework, then add paging (`offset`, server caps 200) + per-station filter (uses ignored `stationID`).

### S3 — Steering + policy (can bundle into S2's Mini deploy)
- **Boost-as-steering** (signal-model doc §3, unbuilt step 2): seed-override + debounced refill — controller seam in `LastFMStationController`, plumbing through `TrackSource` wrappers, trigger in `performBoostAsync`. Boost becomes "point the radio", not just a rating.
- **`/policy/get` + `/policy/set`** (owner): global `newMusicShare` dial + `excludeMixSets` toggle — the machinery is fully wired and re-read live per refill (`RadioBroadcaster.swift:714`), it just has no UI anywhere.
- **W4 (client)**: two policy controls in the stations panel.

### S3b — Transparency endpoints (parallel with S2/S3) + W5 (client)
- **`POST /taste`** (owner): top artists/tags, ♥/boost/skip counts from `TasteProfile` + `HistoryStore`.
- **`POST /exclusions`** (owner, station+limit scoped): "why this track" from the persisted `selection_exclusions` audit rows (`SelectionPlanner.swift`, `HistoryStore.exclusions`).
- **W5**: taste + why-this-track panels.

### S4/W6 — Library Radio kind (last; largest)
New `Station.Kind.libraryRadio` + config per signal-model doc §4 (self-seeding from library + taste). **Forward-compat is the risk**: `StationStore` v1 per-entry fail-open decode must tolerate the unknown kind in older builds without wiping (verify exact behavior; `StationManager.setStorage` currently collapses decode failure to `[]` then overwrites — state and test the actual outcome before shipping). `excludeOwnedLibrary` editable (review G6). Web create gated on `vocab.kinds`.

## Verification

- **XCTest** (existing CI is the only automated gate): extend `RadioBroadcasterTests` raw-NWConnection pattern (`fetchRawResponse`, :951) for every new route incl. auth-gating, 410/413/503 paths, listener-hole recovery (mirror `testListenerRecoversFromABindConflict` :361 with per-station stops); `StationManagerTests` for `applyUpdate` id-preservation, validation, slug re-key.
- **Outside-in**: new `verify-control-plane.sh` (lands with S2, wired into `install.sh` after its trap-based throwaway-station cleanup is itself tested — it writes to the Drive-synced stations file): authed create→list→update→start→stop→delete round-trip through Cloudflare against a throwaway station; `install.sh`'s existing 120s outside-in audio verification stays.
- **Manual per milestone (~5 min)**: phone + laptop on ratbat.fm — login, create a station, watch it appear in the Mini's desktop sidebar (screen-share/VNC), edit tags with "Save & restart", boost a track and observe the refill, kill SSE (toggle wifi) and confirm poll fallback.
- **Version skew**: after each Pages deploy, verify the site against the *old* server (features hidden, nothing broken) before the Mini deploy.

## Key risks

1. **Listener-hole lockout** (S1.3 fixes; must precede any web stop).
2. **StationStore silent wipe**: never bump `currentVersion`; new kind must decode fail-open per-entry — test with an old binary against a new file before S4 ships.
3. **Body truncation on slow tunnel** → S1.5's deadline+413.
4. **Drive conflict-copies**: Mini is sole writer; MacBook stops creating stations (document).
5. **Passcode blast radius now includes delete**: mitigated by typed-name confirm + existing throttle; accepted per user decision.
