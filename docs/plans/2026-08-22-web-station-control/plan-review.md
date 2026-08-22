# Cross-Review: Server / Client / Rollout Plans

Verified against `ratbat`@adeecbb and `ratbat.fm`@963be6d.

## 1. API-shape mismatches (server ↔ client ↔ rollout)

| # | Surface | Server plan | Client plan | Rollout plan | Recommended resolution |
|---|---|---|---|---|---|
| M1 | Station id field in write bodies | `{"station": "UUID"}` (matches shipped `LikeRequest`, RadioBroadcaster.swift:2323) | `{id: …}` on update/delete/start/stop | — | **`station`.** Matches every shipped route; one envelope name across the wire. |
| M2 | Create/update payload nesting | Flat: `{kind, name, query, sort, exploration, shufflePool}` | Nested: `{kind, name, config:{query, shufflePool, sort, exploration}}` | — | **Flat.** Nesting invites the client to POST a `config` blob that server-side maps to four different Swift structs; flat maps 1:1 to `StationUpdate`. |
| M3 | `/stations/list` response | Flat `StationPayload` (`query`, `exploration`, `sort`, `shufflePool` at top level) | `{id, slug, name, kind, broadcasting, config:{…}}` | — | **Flat**, same as M2. Client's editor code must read the same shape it writes. |
| M4 | Kind string casing | `"lastfm"` | `"lastFM"` | — | **`lastFM`.** It's the synthesized `Station.Kind` coding key (Station.swift:47) and the `StationTagPalette.lastFM` name (StationTagPalette.swift:31); `"lastfm"` creates a second spelling to maintain. |
| M5 | Vocab route | `GET /vocab` | `GET /vocab` | `POST /config/vocab` | **`GET /vocab`** (2 of 3, no auth needed, cacheable). Drop `/config/vocab`. |
| M6 | Vocab payload keys | `{palettes:{nts,lastfm,bandcamp}, tagMatch, popularity, bandcampSort, kinds, regions:[ISO codes]}` | `{tags:{nts,lastFM,bandcamp}, regions:[{code,label}], …}` | "StationTagPalette per source, region codes, popularity tiers, sort, tagMatch" | **`tags` key name** (client reads `vocab.tags[kind]`), `lastFM` casing, **regions as bare ISO codes** (server plan is right — `Intl.DisplayNames` localizes client-side, and `Locale.Region.isoRegions` is the shipped source, FacetedQueryEditor.swift:197). Keep server's `kinds` array — it doubles as the Library-Radio capability signal (see G4). |
| M7 | Exclusions route name | `POST /exclusions` (station-scoped list) | `POST /why {token, station?, limit}` | `POST /why {entryID or historyID}` + "winning track's score components" | **`POST /exclusions`, station+limit scoped.** Rollout's per-entry variant needs a join from `entryID` → the exclusion rows of that refill, which nothing persists; and "score components" are not stored at all. Cut that clause. |
| M8 | Capability detection | **None** — server `/health` has no `capabilities`/`version` field | Per-endpoint 404 probing into a client-side `capabilities` object | `/health` returns `capabilities: [string]`, append-only, as *the* anchor; `verify-control-plane.sh` asserts non-empty | **Pick one: `/health.capabilities` + `version`.** This is the largest three-way divergence. 404-probing costs an extra owner POST at boot, can't distinguish "route absent" from "catalogue unavailable" (see M11), and rollout's verify script fails against the server plan's `/health` as specified. Add `capabilities` and `version` to the server's `buildHealthPayload`; client keeps 404-tolerance only as belt-and-braces. |
| M9 | `/health` payload | `{status, now, broadcastingCount, stations:[{…, liveness, offAirGaps[]}]}` | needs uptime (`● on air · 3d 4h · 2 live`) + one recent gap | `{status, version, capabilities, liveness, offAirGaps}` — **top-level** `liveness` | `HistoryStore.liveness(station:from:to:)` is **per-station only** (HistoryStore.swift:815) — rollout's top-level field has no source. Keep server's per-station array, **add top-level `uptimeSeconds`** (client renders it) and `capabilities`/`version`. Cut per-station 24 h `offAirGaps` arrays to a single most-recent gap — the client renders one line. |
| M10 | `/policy/set` fields | decodes `token`, `newMusicShare`, `excludeMixSets` only | sends `mixSetMinimumDuration` and renders a minutes input | lists `mixSetMinimumDuration` in the policy triple | **`mixSetMinimumDuration` is not persistable.** BroadcastPreferences.swift:155-176 — the getter hardcodes `MixSetRule.defaultMinimumDuration` and the setter drops it. Server plan is accidentally correct; the client control and rollout's mention are dead. Either drop the control (recommended) or add a `mixSetMinimumDurationRaw` default in this scope. |
| M11 | Catalogue-unavailable status | `503 {"status":"error","message":"catalogue unavailable"}` when no music folder | treats only 200 as capable, 404/network as absent — **503 is unhandled** | — | Client must treat 503 on `/stations/list` as "server capable, temporarily unusable" and show the message, not silently hide the panel. |
| M12 | 410 status | added to the status-text table; **no route emits it** | `friendlyError` maps 410 → "Station no longer exists" | listed in S1.4 | Emit 410 (not 404) from `/stations/update|delete|start|stop` when the UUID parses but no station exists, so the table entry is load-bearing. Otherwise drop 410. |
| M13 | SSE event naming | existing 5 call sites stay **unnamed** for back-compat; only `stations` named | handles both `onmessage` and `addEventListener('now')` | `sseEvent` gains `event:` lines for **both** `now` and `stations` | There are **zero `EventSource` consumers today** (verified: no `EventSource` in app.js), so the back-compat contract protects nothing. **Name everything** (`now`, `stations`) per rollout; the client already listens to both paths, so it degrades either way. |
| M14 | SSE heartbeat | not addressed | asks for a named `event: ping`; falls back to a 90 s guess-watchdog | R6 suggests a `: keepalive` comment frame | The shipped heartbeat is already `": heartbeat\n\n"` every 30 s (RadioBroadcaster.swift:1910) — a **comment**, invisible to `EventSource`. Rollout's R6 mitigation is already shipped and doesn't help the client. Change that one line to `event: ping\ndata: {}\n\n` and the client watchdog becomes exact. One-character-class change, high value. |
| M15 | Boost UX copy | — | — | W4: "Boost button copy updated to reflect steering" | Already shipped: app.js:395 says `'Steering toward this ⤴'`. Drop the item. |

## 2. Scoped features missing from all three plans

- **G1 — `mixSetMinimumDuration` has no persistence.** See M10. The "mix-set toggle" half of the scoped dial works; the duration half is a no-op no plan catches.
- **G2 — Request-body limits for CRUD payloads.** Only rollout *mentions* it (R3); the server plan that must implement it says nothing. `readBody` has a **3 s wall clock for the whole body** and returns whatever it has on expiry (RadioBroadcaster.swift:2161-2194) → a slow-tunnel config POST silently truncates into an opaque 400. There is no `Content-Length` sanity check and no 413. Station configs (40 tags + regions + `excludedArtists`) are the first bodies materially larger than `{"station":…,"token":…}`. Needs: raise the deadline for `jsonPostPaths`, reject over ~64 KB with 413, and a socket-path test.
- **G3 — Delete leaves `autoStartSlugs`/`lastLiveSlugs` orphans.** Step 0d re-keys on *rename* only. A web delete followed by recreating a station with the same name silently inherits auto-start.
- **G4 — Nothing sets `autoStart`.** The server's `StationPayload` emits it, rollout's Tier-1 #13 promises a toggle, no route exists and the client never renders it. Either add `/stations/autostart` or remove the field from the payload.
- **G5 — Library Radio has no capability signal on the client.** Client 4d lists it in the kind picker unconditionally; against a pre-S4 server, create returns 422. Free fix: gate the picker on `vocab.kinds`, which the server plan already emits.
- **G6 — `libraryRadio.excludeOwnedLibrary` is not editable.** Server `StationUpdate` carries only `{name, query, sort, exploration}`; the payload doesn't emit `excludeOwnedLibrary` for `.libraryRadio` either. Client 4d renders the checkbox in edit mode. Add both.
- **G7 — `shufflePool` is not editable.** Same hole: emitted in `StationPayload`, accepted on create, absent from `StationUpdate`, present as a checkbox in the client's edit form.
- **G8 — Desktop selection state after a web delete.** RootView's selected-station state when the Mini deletes out from under an open detail pane is unaddressed. Low severity, worth one line of verification.

## 3. Ordering conflicts with the rollout plan

1. **SSE tier is wrong in the rollout.** Rollout gates W2 SSE on S1; the client plan is correct that `onmessage` + unnamed frames + a 30 s heartbeat already work against today's deploy (RadioBroadcaster.swift:1887-1913). Move SSE + poll-backoff to **W1** as the client has it. (Named-event handling ships alongside and lies dormant.)
2. **Health strip placement.** Rollout puts it in W2 (right after S1 ships `/health`); the client puts it last (Step 6 / PR5). Take the rollout's ordering — it's the cheapest proof S1 deployed.
3. **History paging is scheduled before the panel move.** Rollout W1.4 does paging+filter in app.js; client PR2 then deletes that code and reimplements it in panels.js. Take the client's order: framework (PR2) → history upgrades (PR3).
4. **Step 0e (desktop Edit/Add parity) is placed in S1 but depends on Step 2.** The server plan admits exploration has no setter until `applyUpdate` exists. Rollout resolves this with interim `updateExploration` **plus `updatePopularity`** — the latter is unnecessary (popularity lives inside `FacetedQuery`, FacetedQuery.swift:52, so it already flows through `updateQuery`). Either move 0e into S2, or ship `updateExploration` alone.
5. **`verify-control-plane.sh` is wired into `install.sh` in §3.1 but exercises `/stations/*`, which lands in S2.** Land the script with S2, not S1; in S1 the only new probe is `GET /health`.
6. **Rollout's capability-probe scaffold in W1.6 is dead code** — it GETs `/health`, which doesn't exist until S1. Merge it into W2.
7. **Rollout §2 is self-contradictory**: "the server half deploys FIRST" vs. "web PRs can merge freely… ship dark". The client plan's framing (client ships first, capability-gated) is the operative one; reword the rule as *"the server half must be live before a gated feature becomes visible"*.
8. **Server plan's "Steps 2–9 in any order after 1"** understates two real edges: Step 3 needs Step 2 (stated), and Step 9 needs Step 2 (stated) — but Step 4's `stations` push from `registerStations` also needs Step 2's catalogue seam to be *useful*. Not blocking; just note it.

## 4. Scope creep to cut

**Server plan**
- **Temporal-tag normalization** (Step 2.1, `"1990s"` → `yearMin/yearMax`, applied per-kind asymmetrically). Not in approved scope, changes desktop create/edit behavior, and the asymmetry is a permanent explanation cost. **Cut.**
- **Unnamed-frame SSE back-compat contract** (Step 4.1). Protects zero clients. **Cut** — name every event (see M13).
- **Per-station 24 h `offAirGaps` arrays in `/health`.** The client renders one gap line. **Reduce** to a single most-recent gap.
- **`createValidated` as a *second* creation path alongside the retained non-throwing creators.** Two creation surfaces is exactly the drift the plan elsewhere argues against. Migrate the Add sheets onto it in the same step or don't add it.

**Client plan**
- **Permalinks `?station=slug` (3d)** — not in approved scope. **Cut/defer.**
- **Forward-compatible `t.year` / `t.genre` rendering (3a)** — no plan ships those fields. **Cut** (dead branches).
- **"Why it played" score-breakdown stub renderer (5a)** — nothing persists score components. **Cut.**
- **`'N listening'` loosening (3f)**, **theme-color/manifest fix**, **reduced-motion guard**, **`displayDelayFor` (3b)** — all drive-by; each defensible individually, but they belong in one clearly-labelled "polish" PR rather than smuggled into the scoped work.
- **"Create & start" button** — one extra state machine for a two-tap saving. Defer.

**Rollout plan**
- **R2's `versionMismatch` read-only latch + banner.** The plan already forbids a version bump, so the failure mode can't occur in v1. **Cut.**
- **R4's desktop mtime-conflict banner.** Directly contradicts the settled "no file watching, document only" decision. **Cut.**
- **R5(b) server-side per-mutation audit log + per-route throttle escalation.** Beyond "cheap guards only". **Cut** (the unified log already records route hits).
- **`updatePopularity` setter.** Unnecessary — see §3.4.
- **Playwright smoke (3.3).** Self-labelled non-blocking; cutting it preserves the no-build-step property.
- **Keep** `verify-control-plane.sh`, but note it writes to the Drive-synced `.ratbat-stations.json` on every deploy; the trap-based cleanup is the right mitigation and should be tested before the script goes into `install.sh`.

## Minor client-internal note

`panels.js` reading app.js's top-level `const` bindings works (classic scripts share the global lexical scope, and `defer` preserves order), but `syncLock()` is called from inside `render()` (app.js:152), which can fire from `refresh()` before `panels.js` executes. Guard the `onOwnerChange` hook with a `typeof` check rather than assuming registration order.