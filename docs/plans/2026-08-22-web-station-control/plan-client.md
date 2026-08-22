# ratbat.fm Web Client — Implementation Plan (Station CRUD, Transparency, SSE, Hardening)

Verified against `ratbat.fm` @ main (963be6d) and `ratbat` @ main. All paths absolute below; repo-relative paths in prose are relative to `/private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat.fm` (web) and `…/scratchpad/ratbat` (Swift).

## 0. Ground rules and file layout

Zero dependencies, zero build step, classic scripts (no ES modules). Top-level `const`/`function` bindings in a classic script live in the shared global lexical scope, so a second `<script defer>` file can call everything `app.js` defines — no bundler, no `window.` plumbing needed beyond discipline.

**Files after this plan:**
- `index.html` — modified (panel bar + panel sheet + dialogs + theme-color fix + second script tag).
- `js/app.js` — modified in place (transport, meta rendering, boot auth, permalinks). Stays the player/grid file. History code moves OUT (to panels.js).
- `js/panels.js` — NEW (~700 lines). Panel framework, station editor, transparency panels, dialogs, `/vocab`+capability probes, health strip, selection-policy controls. Loaded after app.js: `<script src="js/panels.js" defer></script>`.
- `css/style.css` — modified (new tokens + one new "forms & panels" section, ~150 lines added).
- `manifest.json` — one-line `theme_color` alignment.

**Shared-surface contract between the two JS files** (all already top-level in app.js): `API_BASE`, `ownerKey()`, `storeOwnerKey()`, `escapeHtml()`, `timeoutSignal()`, `stations` (read), `showNote()`, `render()`, `refresh()`, `syncLock()`, plus new `apiPost()` and `capabilities` (defined in app.js, consumed by panels.js).

**Ordering principle:** Steps 1–3 are Tier-0 — they run against the currently deployed broadcaster (which already serves `/events`, `/history?limit&offset` with `station`/`stationID`, and `album/durationSeconds/origin` on every track). Steps 4–6 depend on the new server API and are gated behind runtime feature detection, so the client ships first and degrades gracefully until the Mini is redeployed.

---

## Step 1 (Tier-0): Transport — SSE with poll fallback + backoff

**app.js changes:**

1. **Split `refresh()` (app.js:128-146)** into `fetchNow()` (the fetch + error handling) and `adoptNow(data)` (absolutize `streamURL` against `API_BASE`, stop if `activeId` vanished, `render()`, `syncTitle()`). SSE and polling both funnel through `adoptNow` so there is exactly one ingestion path.
2. **New `connectEvents()`**: if `window.EventSource` is absent, poll forever (status quo). Otherwise open `new EventSource(`${API_BASE}/events`)`.
   - `es.onmessage` — the current server sends **unnamed** `data:` frames (RadioBroadcaster.swift sseEvent ~:2085, endpoint ~:1887) carrying a full now.json snapshot → `adoptNow(JSON.parse(e.data))`. This is why SSE is Tier-0: it works against today's deploy.
   - `es.addEventListener('now', …)` and `('stations', …)` — future named events from the new server. `now` → `adoptNow`; `stations` → set `ownerStationsDirty = true` and, if the Stations panel is open and owner mode is on, call `loadOwnerStations()` (defined in Step 4). **Owner data must never ride SSE** — `/events` is public with `Allow-Origin: *`; the named `stations` event is a change *notification*, and the client re-fetches the owner-gated `POST /stations/list` with the token. State this loudly in a comment.
   - `es.onopen` → `sseAlive = true`, cancel the poll timer, reset backoff.
   - `es.onerror` → `es.close()`, `sseAlive = false`, schedule reconnect with exponential backoff `min(1000 * 2^n, 30000)` + 20% jitter, and resume polling meanwhile.
   - **Staleness watchdog**: the server heartbeat is an SSE *comment* (`: heartbeat`), invisible to EventSource. Keep a `lastEventAt` timestamp; a 90s `setInterval` that fires only while `document.visibilityState === 'visible'` tears down and reconnects if exceeded. (Flag for the server plan: a named `event: ping` heartbeat would make this exact instead of best-effort.)
3. **`schedulePoll()` (app.js:473-480)**: becomes fallback-only — early-return when `sseAlive`. Add failure backoff: `refresh()` sets `pollFailures++` on catch, 0 on success; delay = `pollFailures ? min(POLL_FAST * 2**pollFailures, 30000) : (stations.length ? POLL_SLOW : POLL_FAST)`. This fixes the current 1.5s hammering of a down broadcaster.
4. `visibilitychange` handler (app.js:541-543): also nudges the watchdog / reconnects a closed EventSource immediately.
5. Boot line (app.js:624) becomes `refresh().then(() => { connectEvents(); schedulePoll(); })` — one poll-path bootstrap for first paint, then SSE takes over.

---

## Step 2 (Tier-0): Panel framework, form primitives, dialogs, CSS tokens

### 2a. index.html
- Replace `<aside id="history">` (index.html:31) with:
  ```html
  <nav id="panelbar" aria-label="Panels"></nav>
  <aside id="panel" hidden></aside>
  <dialog id="dlg"></dialog>
  ```
- Fix the theme-color conflict (index.html:8): two media-scoped metas — `<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">` and `…content="#000000" media="(prefers-color-scheme: dark)">` (matches `--bg` dark `#000`, style.css:19). Set `manifest.json` `theme_color` to `#000000` to agree.
- Add `<script src="js/panels.js" defer></script>` after app.js.

### 2b. panels.js — the framework (copies the #history pattern, generalized)
The report's key finding stands: `render()` destroys everything inside `#stations` every 1.5–3s, and `#history` escapes because it is a sibling with its own render function. **Cheapest coexistence change: do not touch `render()`'s structure at all.** All new UI lives in `#panelbar` / `#panel` / `#dlg`, which `render()` never writes to. No incremental-render rewrite — it is not justified: no form state ever enters `#stations`; the only grid additions (Step 3) are stateless text and one stateless button.

- `let activePanel = null;` `const PANELS = { history, stations, why, taste }` — each entry `{label, ownerOnly, cap, load(), renderInto($panel)}`.
- `renderPanelBar()` — buttons for each visible panel (guests see only "Play history"; owner panels appear when `ownerKey()` is truthy AND the capability probe passed). Bar left edge hosts the **health strip** (Step 6). Called from `syncLock()` via a hook (`onOwnerChange` callback app.js invokes) and after capability probing.
- `openPanel(name)` / `closePanel()` — one panel open at a time; sets `hidden`, `.open` class, calls `load()` then `renderInto()`. Escape key closes.
- **Move history here**: delete `loadHistory`/`renderHistory`/`historyOpen`/`historyRows`/`$history` block from app.js (app.js:485-539) and reimplement as the `history` panel (Step 5c adds paging + filter). Net app.js shrinkage offsets transport growth.
- `openDialog({title, bodyHTML, confirmLabel, danger, validate})` helper over the single `<dialog id="dlg">` — used by login, logout-confirm, and delete-confirm. Focus is trapped natively by `showModal()`; return a Promise.
- **Replace native prompt/alert/confirm in `unlock()` (app.js:575-600)**: `unlock()` stays in app.js but delegates to `panels.js`'s `loginDialog()` — a passcode `<input type="password">` + inline error line ("Wrong passcode." / "Couldn't reach the broadcaster…") instead of `alert()`. Logout uses `openDialog` confirm.

### 2c. style.css additions
Extend `:root` (style.css:1-15) — dark mode stays automatic because everything routes through tokens (dark overrides at :17-28 gain only `--danger`):
```css
--fs-small: clamp(.75rem, 1.9vmin, .95rem);  /* tokenizes the repeated clamp */
--radius: 2px;            /* hairline aesthetic; near-square */
--space: .6rem;
--danger: #c22;           /* dark: #f66 */
--chrome-h: 2.4rem;       /* replaces the magic number in main padding-bottom, style.css:343 */
```
New section (~150 lines): `#panelbar` (fixed bottom bar, identical recipe to old `#history` bar: hairline top border, safe-area padding, `z-index:10`); `#panel` (fixed above the bar, `max-height:60dvh; overflow-y:auto`, same borders); form primitives — `.field` (label + control column, label in `--muted` `--fs-small`), `input[type=text|password|number|search], select, textarea` (1px `var(--border)` border, `var(--bg)` background, `var(--radius)`, focus `outline: 2px solid var(--border-strong)` matching the existing focus idiom at :86/:216); `.chips`/`.chip` (tag tokens: hairline border, `.chip.on { background: var(--active); border-color: var(--border-strong) }`, tap toggles); `.btn`, `.btn--primary` (border-strong), `.btn--danger` (`--danger` text/border); `.seg` segmented control (any/all); `dialog` + `dialog::backdrop` (`color-mix` scrim, matching the `#lock` idiom at :372); `.row` list rows for panels. Also add the missing `@media (prefers-reduced-motion: reduce)` guard killing `pulse`/`blink`/`spin` — we're adding UI, not more motion.

### 2d. Grid affordances (the only `render()` touches for chrome)
- Per-card **✎ edit** (owner-only): one quiet button in the card **`.head`** (app.js:269-272), after `.name`, class `act act--edit`, `data-id`, opacity styled like `.act` (:204). It only calls `openStationEditor(id)` in panels.js — never inline UI. The `.foot` action row stays at its four-action ceiling.
- **＋ New station** and **⚙ Stations** live in `#panelbar` (owner-only), not on the grid. The grid stays a radio.
- Click delegation: add `act--edit` branch in the `#stations` click handler (app.js:288-309).

---

## Step 3 (Tier-0): Richer text-only now-playing meta + hardening quick wins

All data already on the wire with explicit nulls (`NowTrack` at RadioBroadcaster.swift:3025-3064: `title, artist, album, durationSeconds, artworkURL, sourceURL, youtubeURL, origin`). **No images — ignore `artworkURL` entirely.**

### 3a. `render()` additions inside the `.now` block (app.js:171-281)
- **Album line**: after `.artist`, `t.album ? `<span class="album">${escapeHtml(t.album)}</span>` : ''` — muted, `--fs-small`, ellipsis (new CSS rule beside `.artist`, style.css:148).
- **Progress as text** (active card only): `<span class="progress" data-station="${s.id}">2:41 / 6:05</span>`. Elapsed is client-estimated: when `displayTrack` adopts a new `shownKey` (app.js:59, :72), stamp `shownAt: performance.now()` into the `displayState` entry. Elapsed = `now - shownAt`, clamped to `durationSeconds`. Render emits the current value; a 1-second `setInterval(tickProgress, 1000)` patches only `document.querySelectorAll('.progress')` `textContent` — it survives the destructive re-render because render always re-emits the freshly computed string, and the tick never touches anything else. When `durationSeconds` is null, show elapsed alone (`3:12`); helper `fmtClock(secs)`.
- **Origin badge** in the `.nowlinks` row (app.js:259-261): `<span class="origin">${escapeHtml(t.origin)}</span>` mapped to display text (`nts → NTS`, `lastFM → Last.fm`, `bandcamp → Bandcamp`, `library → Library`), small-caps muted chip. Render for all origins.
- **Forward-compatible fields**: if `t.year` / `t.genre` appear (Tier-3 server work), append `· 1997 · dub techno` to the album line — `if (t.year || t.genre)` guards mean older servers render nothing.
- **Timeline timestamps**: `recent[].playedAt` is already served — prefix recent rows (app.js:245-252) with `HH:MM` in `--muted`, reusing the history `fmt` helper (move it to a shared `fmtTime()`).

### 3b. `DISPLAY_DELAY_MS` derived from duration
Replace the constant (app.js:50) with:
```js
const DISPLAY_DELAY_MS = 10_000; // ceiling — ring + browser buffer
const displayDelayFor = (t) =>
  t && t.durationSeconds
    ? Math.max(2_000, Math.min(DISPLAY_DELAY_MS, t.durationSeconds * 1000 / 3))
    : DISPLAY_DELAY_MS;
```
and use `displayDelayFor(st.pendingTrack)` in the comparison at app.js:71. Rationale: 10s remains the buffer-lag ceiling, but a track shorter than ~30s must not be held longer than a third of its runtime or the display never catches up (interstitials/IDs). Comment this in place.

### 3c. Boot-time `/auth` validation
New `validateStoredKey()` in app.js, called fire-and-forget at boot (next to app.js:624) and on `visibilitychange`-visible if the last attempt returned `null`:
- No stored key → no-op. `checkOwnerKey(stored)` (app.js:553-565) `=== false` → `storeOwnerKey(null); syncLock(); render();` and a one-time note on the active card ("Passcode no longer valid — tap the lock"). `=== null` (unreachable) → keep the key, mark for retry. This closes the "🔓 lies until first failing action" hole and gives panels.js a trustworthy owner signal before showing destructive UI.

### 3d. Permalinks `?station=slug`
- `slug` is already in every `/now.json` station entry. On `adoptNow`, if `new URLSearchParams(location.search).get('station')` matches a station's `slug` and nothing is active yet, add class `armed` to that card (highlight ring; autoplay policy forbids playing) and scroll it into view on mobile. First tap plays as usual.
- In `toggle()` (app.js:416-428): after activating, `history.replaceState` the URL to include `?station=<slug>` (preserving `?api=`); on `stop()`, remove it. Cheap, shareable, zero server cost.

### 3e. Central `apiPost()` + error surfacing
New helper in app.js:
```js
async function apiPost(path, body, ms = 8000) → {ok, status, data}
```
— wraps fetch(POST JSON, `timeoutSignal(ms)`), parses JSON with fallback `{}`, and centralizes **403 → `storeOwnerKey(null) + syncLock() + render()`** (currently only in `sendAction`, app.js:363-371). Add `friendlyError(status, data)` mapping: 401/403 → "Passcode no longer valid", 404 → "Not available on this broadcaster", 409 → "That name is taken", 410 → "Station no longer exists", 422 → "Check the form", 5xx/network → "Broadcaster hiccup — try again". Refactor `sendAction` (app.js:351-414) and `checkOwnerKey` onto it (behavior-preserving; keep the `saved/noted/409` like-semantics branches). Every panels.js call uses `apiPost`.

### 3f. 'N listening'
Loosen app.js:228-230: show the listener count on **every** live card when `listeners > 1` (not only the active one), still yielding to an active note; keep the `title` tooltip. On the active card show it even at `1` as "you're listening" is noise — keep `> 1` there too (minimal change, but no longer active-card-gated).

---

## Step 4 (server-gated): Capability detection + Station editor (create/edit/delete/start/stop)

### 4a. Assumed API contracts (from the settled decisions; the server plan owns the exact shapes — coordinate on these)
All POST, token in JSON body, added to the OPTIONS allow-list; new status texts 201/403/409/410/422:
- `POST /stations/list {token}` → `{stations:[{id, slug, name, kind, broadcasting, config}]}`; `kind ∈ nts|lastFM|bandcamp|libraryRadio|playlist`; generative kinds carry `config` = `{query:{genreTags, yearMin, yearMax, regions, tagMatch, popularity, excludeOwnedLibrary}, shufflePool, sort?, exploration?}` (mirrors NTSStationConfig/LastFMStationConfig/BandcampStationConfig fields verified in `RatbatCore/Radio/…Config.swift`); `libraryRadio` carries `{exploration, excludeOwnedLibrary, seedCount}` (signal-model doc §4); **playlist projected to `{kind:"playlist", trackCount}`** — the client must render playlist rows read-only (no edit, no delete in v1).
- `POST /stations/create {token, kind, name?, config}` → 201 `{station}`; `POST /stations/update {token, id, name?, config, applyNow}` → 200 `{station}`; `POST /stations/delete {token, id}`; `POST /stations/start|stop {token, id}`.
- `GET /vocab` (public) → `{tags:{nts:[…], lastFM:[…], bandcamp:[…]}, regions:[{code,label}], popularity:[hits,middle,deepCuts], tagMatch:[any,all], bandcampSort:[…]}` — serialized `StationTagPalette` + enums, so JS never hardcodes Swift constants.

### 4b. Feature detection (`probeCapabilities()` in panels.js)
Runtime, per page load, memory-only (the Mini can be redeployed any time; never cache in localStorage):
- `capabilities = { stations:false, vocab:false, health:false, policy:false, why:false, taste:false }`.
- Public probes at boot: `GET /vocab` and `GET /health` (200 → true; 404/network → false).
- Owner probes after `validateStoredKey()` succeeds: one `POST /stations/list` — 200 sets `stations:true` AND doubles as the initial owner-station load; 404 → old server → the Stations/Why/Taste bar buttons simply never render. `policy/why/taste` probed lazily on first panel open (404 → panel body shows "Not available on this broadcaster yet — redeploy the Mini"). Older server degrades to: exactly today's UI + Steps 1–3 improvements.

### 4c. Stations panel (`renderStationsPanel()`)
State: `let ownerStations = []`, `loadOwnerStations()` via `apiPost('/stations/list', {token})`.
- Row per station: broadcasting dot (reuse `.dot`), name, kind badge (same origin-badge styling), then quiet text buttons: `Start`/`Stop`, `Edit`, `Delete`. Playlist rows: badge + "N tracks", no Edit/Delete.
- `＋ New station` row at top → kind picker (NTS / Last.fm / Bandcamp / Library Radio) → editor form.
- Start/Stop: optimistic dot flip + row busy state; reconcile from response; the public grid updates via the SSE `stations`/`now` push (server plan adds `pushSSE()` on start/stop).

### 4d. Editor form (`renderStationForm(mode, station?)` + `submitStationForm()`)
One form for create and edit; kind immutable after create. Fields by kind (from the verified configs):
- **Common (NTS/Last.fm/Bandcamp)**: name (text; blank = server default), **tags** — chip cloud from `vocab.tags[kind]` (tap to toggle) + a free-text input that adds arbitrary chips ("Tags outside a palette still round-trip fine", StationTagPalette.swift:14); tagMatch `any|all` segmented; year range (two `number` inputs, placeholder "any"); regions multi-chip from `vocab.regions`; `excludeOwnedLibrary` checkbox ("only music I don't own"); `shufflePool` checkbox.
- **Last.fm only**: popularity select (hits/middle/deepCuts), exploration slider 0–1 (rendered `0–100%`). (Desktop parity fix for EditStationView is a stated prerequisite in the app repo, so web and Mac expose the same set.)
- **Bandcamp only**: sort select from `vocab.bandcampSort`.
- **Library Radio**: exploration slider, `excludeOwnedLibrary` checkbox (default on), `seedCount` number (default 8). No tags — say so in helper text: "Seeds itself from your library and boosts."
- Client-side validation mirroring the server: ≥1 tag for generative kinds, `yearMin ≤ yearMax`, `seedCount ≥ 1`. Inline field errors; 422 responses map `data.message` under the form; 409 under the name field.
- **Buttons**: `Cancel` · `Save` (`applyNow:false`) · — shown only when the station is currently `broadcasting` — `Save & restart station` (`applyNow:true`) with the desktop's honesty line beneath: "Restart cuts the track that's playing for every listener." Create mode: `Create` · `Create & start` (create then `/stations/start`).
- **Delete**: `openDialog` with danger styling — "Type **{name}** to delete this station" — a text input compared trim/case-insensitively against the name; the red Delete button enables only on match. On success: remove row, close, note.
- **Optimistic UI + reconciliation**: on submit, patch `ownerStations` locally and render the row in a `saving` state; on 2xx replace with the server's returned station (authoritative slug/name uniquing — the server may append "(2)"); on error revert + inline message. The SSE `stations` notification triggers `loadOwnerStations()` re-fetch (never trust the public event body for owner data). Document the accepted risk: desktop and web are last-write-wins; the Mini is authoritative and the MacBook reflects on relaunch.

### 4e. Selection-policy controls (global, v1)
A "Selection policy — all stations" fieldset at the bottom of the Stations panel, gated on `capabilities.policy` (`POST /policy/get` / `POST /policy/set {token, newMusicShare, excludeMixSets, mixSetMinimumDuration}`):
- **newMusicShare is nullable and null ≠ 0** (SelectionPolicy.swift:26-31): render a checkbox "Prefer a share of new music" that enables a 0–100% slider; unchecked sends `null`. Helper text: "'New' means artists you own nothing by."
- `excludeMixSets` checkbox + minimum-duration minutes input (enabled only when checked).
- Save button; optimistic with revert-on-error.

---

## Step 5 (server-gated + Tier-0 parts): Transparency surfaces

### 5a. Why-this-track panel (`why`)
Gated on `capabilities.why` (`POST /why {token, station?, limit}` serving `HistoryStore.exclusions()` rows — schema verified at HistoryStore.swift:1027-1046 / `Exclusion` struct :48-68).
- Header: station `<select>` (from `ownerStations`, default = the active card's station).
- Section "Filtered out recently": rows `artist — title` · arm badge (`duration`/`title`) · detail (`matchedText` for title arm, `fmtClock(durationSeconds)` for duration arm) · `enforced ? "dropped" : "would drop (filter off)"` · `×hit_count` · relative `last_excluded_at`. This is the audit the mix-set filter's "shadow log" exists for.
- Forward-compatible: if the server later ships per-refill score breakdowns, render a "Why it played" section keyed on the same panel — leave a stub renderer.

### 5b. Taste-profile panel (`taste`)
Gated on `capabilities.taste` (`POST /taste {token}` → top artists with ♥/⤴ counts, top tags, totals, and current newMusicShare realized ratio/shortfall if provided). Render as two plain text columns (Top artists / Top tags) + a totals line ("214 ♥ · 38 ⤴ · 91 👎"). Pure text, `#history`-style rows; no charts, no deps.

### 5c. History panel upgrades (Tier-0 — server supports these today)
In the relocated history panel (panels.js):
- **Paging**: keep `limit=100`; a "Show more" row appends `offset += 100` pages (`/history?limit=100&offset=N`, clamped server-side per RadioBroadcaster.swift:2966-2976) until a short page returns.
- **Per-station filter**: rows already carry `station` (display name, null if deleted) and `stationID`. A `<select>` built from the distinct values of loaded rows (plus live station names); filtering is client-side over the accumulated rows and persists across "Show more". Show "(deleted station)" for null names.
- **Retro-♥ in history: explicitly deferred.** `recent[].entryID` is a UUID string; history rows expose `Int64 id` — `/like` cannot address them. Note it as an optional server ask (accept `historyID` in LikeRequest); do not fake it client-side.
- Optional polish: while the panel is open and SSE is alive, prepend on `now` events instead of requiring reopen.

## Step 6 (server-gated): Health strip
Gated on `capabilities.health` (`GET /health`, public, from the heartbeat table: `liveness()` / `offAirGaps()`).
- `loadHealth()` on boot + every 60s while visible (or on a future SSE `health` event). Render into the left side of `#panelbar` as one muted line: `● on air · 3d 4h · 2 live` or `○ off air since 14:02`; a recent outage gap appends `· gap 6m at 09:12`. Dot reuses `--dot` / `--muted`. On old servers the strip simply doesn't render.

---

## Sequencing summary (PR-sized chunks, Tier-0 first)
1. **PR 1**: Step 1 transport (SSE + fallback + backoff) — deployable immediately, works on today's server.
2. **PR 2**: Step 2 framework (panel bar/sheet, dialogs, CSS tokens/primitives, history relocated, login dialog, theme-color fix).
3. **PR 3**: Step 3 (text meta, displayDelayFor, boot auth, permalinks, apiPost + error map, listening count) + Step 5c history paging/filter. ← end of pure-client work; ship all of it before the Mini redeploys.
4. **PR 4**: Step 4a-d capability probing + station CRUD (dark until the server ships; verify degradation against the live old server via `?api=`).
5. **PR 5**: Step 4e policy + Step 5a/5b transparency + Step 6 health.

**Testing without a build step**: run against the real deployed (old) broadcaster via `https://ratbat.jonasjohansson.se/?api=…` overrides and a local new-build Mini (`?api=http://localhost:18000`) to exercise both sides of every capability gate; check iOS Safari (dialog support, `AbortSignal.timeout` fallback already handled), dark mode, and the reduced-motion guard.

**Coordination asks recorded for the server plan** (client assumes them, degrades without them): named SSE events `now`/`stations` (+ ideally `ping`), `pushSSE` on start/stop, `/stations/*` + `/vocab` + `/health` + `/policy/*` + `/why` + `/taste` per contracts above, playlist projection with `trackCount`, status-text table additions, `/history` prefix-match tightening, empty-pipelines rebind fix before web stop ships, autoStartSlugs re-key on rename.

### Critical Files for Implementation
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat.fm/js/app.js — transport split (`fetchNow`/`adoptNow`/`connectEvents`), `apiPost`, `validateStoredKey`, meta rendering in `render()`, `displayDelayFor`, permalinks
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat.fm/js/panels.js — NEW: panel framework, station editor, dialogs, capability probes, transparency panels, health strip
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat.fm/css/style.css — tokens (`--fs-small`, `--danger`, `--radius`, `--chrome-h`), form/chip/dialog/panel primitives, reduced-motion guard
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat.fm/index.html — panelbar/panel/dialog nodes, theme-color media pair, second script tag
- /private/tmp/claude-501/-/908d432a-9507-4650-801a-915c8dc9c693/scratchpad/ratbat/RatbatCore/Radio/RadioBroadcaster.swift — the wire contracts the client codes against (SSE :1887/2085, /history :2960-2977, NowTrack :3025-3064, CORS :2199-2207)