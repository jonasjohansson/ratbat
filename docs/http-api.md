# Ratbat HTTP API

The broadcaster's complete HTTP surface, as served by `RadioBroadcaster`
(`RatbatCore/Radio/RadioBroadcaster.swift`, with the station control
plane in `StationWire.swift` and steering/transparency in
`SteeringWire.swift`). Those three files are the source of truth; this
document mirrors them so the web client and the verify scripts have a
spec to read that isn't Swift.

- **Origin**: `http://localhost:18000` on the broadcasting machine,
  published as `https://radio.jonasjohansson.se` through a Cloudflare
  tunnel. Everything below is reachable from the public origin.
- **Verbs**: reads are `GET`; every action is a `POST` with a JSON body
  and a path-verb (`/stations/create`, not `PUT /stations`). There are
  no query-string parameters except on `/history`.
- **Auth**: a single shared owner passcode, sent as `token` **in the
  JSON body** — never a header, never a cookie, no sessions. Comparison
  is whitespace- and case-insensitive (the passcode is typed by humans
  on phone keyboards). Rejection is always `403 {"status":"error",
  "message":"listener mode"}`; consecutive failures buy a growing
  server-side delay, and a success resets the count.
- **CORS**: every JSON route answers with `Access-Control-Allow-Origin:
  *`, methods `POST, OPTIONS`, headers `Content-Type`. `OPTIONS` on any
  JSON POST path returns `204` (preflight); the preflight allow-list and
  the POST dispatch share one `Set`, so a route cannot exist for one and
  not the other.
- **Wire shape rule**: every key is present on every object, always —
  `null` where a field has nothing to say, never a missing key. Keys are
  sorted. Clients must ignore unknown keys (all changes are additive).
- **Body limits**: JSON POST bodies over 64 KB are refused with `413`;
  the body read has a 10 s wall clock, sized for a station config
  arriving over a slow mobile link.
- **Errors**: JSON routes answer `{"status":"error","message":"…"}` with
  a meaningful status code — see the table at the end.

## Capability detection

`GET /health` is the anchor. Its `capabilities` array is **append-only**
— strings are never renamed or removed within v1:

```
health, stations, vocab, policy, taste, exclusions
```

Client rules: probe `/health` once per page load; a 404 (pre-capability
server) means an empty capability set; render owner UI only for
capabilities present. `vocab.kinds` additionally gates the create-form
kind picker (`libraryRadio` appears there only when the serving build
supports it — S4 and later).

---

## Public reads (no auth)

### `GET /now.json`

The currently **broadcasting** stations only (idle stations never appear
here — that's what owner-gated `/stations/list` is for), each with its
current, recent, and upcoming tracks.

```json
{
  "stations": [
    {
      "id": "UUID",
      "name": "Ambient FM",
      "slug": "ambient-fm",
      "broadcasting": true,
      "streamURL": "/stream/ambient-fm.aac",
      "listeners": 2,
      "currentTrack": { /* Track, or null */ },
      "nextTrack": { /* Track, or null */ },
      "recent": [ { /* Track + "entryID": "UUID", "playedAt": 1755870000.0 */ } ]
    }
  ]
}
```

Track object (`NowTrack`):

```json
{
  "title": "…", "artist": "…", "album": null,
  "durationSeconds": 241.0, "artworkURL": null,
  "sourceURL": null, "youtubeURL": null,
  "origin": "lastfm"                // library | nts | lastfm | bandcamp
}
```

`streamURL` is host-relative on purpose — resolve it against whatever
origin you fetched from. `recent[]` entries carry `entryID` for retro-♥
via `/like`.

### `GET /history?limit=50&offset=0`

Persistent play history (DB-backed; survives restarts). `limit` clamps
to 1–200, `offset` ≥ 0. Public: it only exposes what was broadcast.

```json
{
  "entries": [
    {
      "id": 123, "artist": "…", "title": "…", "playedAt": 1755870000.0,
      "stationID": "UUID", "station": "Ambient FM",
      "saved": false, "youtubeURL": null, "sourceURL": null
    }
  ]
}
```

`station` is resolved against the current catalogue (renames show
immediately); `null` means the station was deleted — the row stays
attributable by `stationID`.

### `GET /health`

Deploy-verification and capability surface. Always `200`; degradation is
a payload fact, not a transport failure.

```json
{
  "status": "ok",                    // "degraded" = up but no history store
  "version": "1.0",                  // CFBundleShortVersionString, "dev" fallback
  "capabilities": ["health", "stations", "vocab", "policy", "taste", "exclusions"],
  "uptimeSeconds": 273906.0,
  "broadcastingCount": 2,
  "stations": [
    {
      "id": "UUID", "name": "Ambient FM", "slug": "ambient-fm",
      "broadcasting": true,
      "liveness": "onAirAndPlaying",   // onAirAndPlaying | onAirButQuiet | offAir
      "lastGap": { "start": 1755800000.0, "end": 1755805000.0 }  // or null
    }
  ]
}
```

Stations listed are those currently broadcasting or heartbeating within
the last 24 h; liveness is judged over a 10-minute window, `lastGap` is
the most recent off-air gap in the last 24 h. `name`/`slug` are `null`
for a deleted station whose heartbeats outlive its catalogue entry.

### `GET /vocab`

Station-form vocabulary — compiled-in constants, public, cacheable
(`max-age=3600`). Single source of truth so web forms never duplicate a
Swift constant.

```json
{
  "tags": { "nts": ["…"], "lastFM": ["…"], "bandcamp": ["…"], "libraryRadio": [] },
  "tagMatch": ["any", "all"],
  "popularity": ["hits", "middle", "deepCuts"],
  "bandcampSort": ["date", "pop"],
  "kinds": ["nts", "lastFM", "bandcamp", "libraryRadio"],
  "regions": ["AD", "AE", "…"]
}
```

`kinds` is what this build can **create over the web** (playlist is
deliberately absent — desktop-only). `regions` are bare ISO 3166 alpha-2
codes; the client localizes names (`Intl.DisplayNames`).
`tags.libraryRadio` is a deliberately empty palette: that kind's tags
filter the owner's own file genre fields, so forms fall back to
free-text entry for it.

### `GET /artwork/{id}.jpg`

Cover art for library tracks, keyed by the hex digest `/now.json` embeds
in `artworkURL`. Immutable per id (`Cache-Control: public,
max-age=86400`). Generative tracks point `artworkURL` at the source CDN
instead, so this route only ever serves library art.

### `GET /events` — Server-Sent Events

Long-lived stream of **named** events:

| event      | data                | when |
|------------|---------------------|------|
| `now`      | full `/now.json` payload | on connect (initial snapshot), then every track change and listener-count move |
| `stations` | `{}` (a poke — refetch `/stations/list`) | any catalogue mutation: create/update/delete, start/stop |
| `ping`     | `{}`                | every 30 s heartbeat |

Fall back to polling `/now.json` when `EventSource` fails repeatedly or
the `health` capability is absent.

### `GET /stream/{slug}.aac`

The audio: raw AAC (ADTS) for the station with that slug, `Content-Type:
audio/aac`, ICY metadata when requested via `Icy-MetaData: 1`. `GET
/stream.aac` (and `/stream`) answer `302` to the first broadcasting
station's slug path — legacy bookmark support — or `404` when nothing is
live.

---

## `POST /auth`

Passcode check with **no side effects** — exists so the web unlock
prompt can say "wrong passcode" without ♥-ing something to find out.
Body `{"token": "…"}` → `200 {"status":"ok"}` or `403`. A malformed or
empty body counts as "no token" (403), never a 400.

---

## Owner actions (token in body, 403 without it)

### Track actions

All take `{"station": "UUID", "token": "…"}`; `404` when the station has
no current track.

| route | semantics | success body |
|---|---|---|
| `POST /like` | ♥ save — copy the playing cached file into the library. With `"entry": "<entryID from recent[]>"`, retro-♥ that recent track instead. Owned tracks record affinity instead of copying. | `{"status":"saved","path":"…","message":null}` (`LikeResponse` shape; also used for errors, with `message` set) |
| `POST /unlike` | undo a ♥ — clears the signal, deletes only the copied file (never a library original). | `{"status":"unliked"}` (`404 "not liked"` when there's nothing to undo) |
| `POST /skip` | 👎 — records a skip (taste signal) and advances. | `{"status":"skipped"}` |
| `POST /next` | ⏭ — advances with **no** taste signal recorded. | `{"status":"next"}` |
| `POST /boost` | "more of this" — records the strongest taste signal **and steers**: the boosted artist is queued as a seed override for the station's next pool refill (debounced). The current track is never interrupted. | `{"status":"boosted"}` |

### Station control plane (`stations` capability)

Station identity is always `"station": "UUID"` in the body. All routes
`503` when no music folder / catalogue is configured ("capable but
unavailable" — distinct from 404), `410` when a UUID parses but resolves
to no station, `400` when it doesn't parse.

**`POST /stations/list`** — body `{"token"}`. The owner's **full**
catalogue, idle stations included (which is why it's owner-gated when
`/now.json` isn't), sorted by name.

```json
{ "stations": [ /* StationPayload */ ] }
```

`StationPayload` — every key on every kind, nulls where a kind has
nothing to say:

```json
{
  "id": "UUID", "name": "…", "slug": "…",
  "kind": "nts",                    // playlist | nts | lastFM | bandcamp | libraryRadio
  "broadcasting": false, "autoStart": false,
  "query": { /* FacetedQuery, or null */ },
  "exploration": null,              // lastFM only, 0…1
  "sort": null,                     // bandcamp only: "date" | "pop"
  "shufflePool": true,              // generative kinds; null on playlist
  "trackCount": null                // playlist only
}
```

**Playlist projection guarantee**: a playlist station serializes to
`kind`/`trackCount` and nulls — never its queue. `Track` carries
absolute `file://` URLs, sizes and dates of the owner's library; the
scrub is enforced in the payload initializer so no route can leak it.
`verify-control-plane.sh` asserts `file://` never appears in a list
response.

`FacetedQuery` (both directions of the wire; `excludedArtists` leaves
sorted):

```json
{
  "genreTags": ["ambient"], "yearMin": null, "yearMax": null,
  "regions": [], "tagMatch": "any",
  "popularity": "middle",           // hits | middle | deepCuts
  "excludeOwnedLibrary": false, "excludedArtists": []
}
```

When **sending** a query (create/update), include every field —
`yearMin`/`yearMax` may be `null` but `genreTags`, `regions`,
`tagMatch`, `popularity`, `excludeOwnedLibrary`, `excludedArtists` are
required by the decoder.

**`POST /stations/create`** — body:

```json
{
  "token": "…",
  "kind": "nts",                    // nts | lastFM | bandcamp | libraryRadio
  "name": "My Station",             // optional; omitted = derived from facets
  "query": { /* FacetedQuery */ },  // required (≥ 1 tag) — except libraryRadio
  "shufflePool": true,              // optional, default true
  "exploration": 0.25,              // lastFM only, optional
  "sort": "date"                    // bandcamp only, optional
}
```

→ `201 {"station": StationPayload}` with the station's **actual** name
(a name collision gets the desktop's "(2)" bump, not an error). `422`
for an unknown kind, an empty tag list, or a Last.fm create with no API
key configured on the server. Playlist stations are not creatable over
the web by design.

`libraryRadio` (S4) relaxes two of those rules: the query is optional
and may carry zero tags (empty filter = the whole library), and no API
key is required — the pool is the owner's own indexed files, played
directly. Facet semantics for it: tags/era filter the files' own tags
(a file with no year is excluded while an era bound is set),
`excludedArtists` are honored, `regions` and `popularity` are ignored
(file metadata carries neither), and `excludeOwnedLibrary` is
meaningless — the server normalizes it to `false`. Updates accept
`name`/`query`/`shufflePool`; `exploration` and `sort` answer `409
wrongKind`. Its `/now.json` tracks report `origin: "library"`.

**`POST /stations/update`** — sparse overlay: absent knobs stay
untouched; `query` replaces the whole query when present.

```json
{
  "token": "…", "station": "UUID",
  "applyNow": false,                // true = restart the live broadcast on the new config
  "name": "…", "query": { … }, "exploration": 0.5,
  "shufflePool": true, "sort": "pop"
}
```

→ `200 {"station": StationPayload}`. Persist happens first, the audible
restart second (`applyNow` on an idle station is a no-op). `409` when a
knob doesn't exist on the station's kind (e.g. `exploration` on NTS, any
`query` on a playlist); `422` for validation failures.

**`POST /stations/delete`** — `{"token","station"}` →
`200 {"status":"deleted"}`. A broadcasting station is stopped first;
the listener and tunnel stay up for whatever remains. Type-the-name
confirmation is the client's job.

**`POST /stations/start`** — `{"token","station"}` →
`200 {"status":"started"}`, idempotent (already-live answers the same
200). `500` with the start error when the pipeline fails to come up.

**`POST /stations/stop`** — `{"token","station"}` →
`200 {"status":"stopped"}`, idempotent even for idle or unknown
stations. Per-station only — there is deliberately no stop-all, and the
listener survives zero stations so the web can't lock itself out by
stopping the last one.

**`POST /stations/autostart`** — `{"token","station","enabled":true}` →
`200 {"status":"ok"}`. Flips the station's launch-time auto-start flag
(per-machine preference on the broadcasting Mac).

### Selection policy (`policy` capability)

**`POST /policy/get`** — body `{"token"}` →

```json
{
  "newMusicShare": 0.3,             // 0…1, or null = dial off
  "excludeMixSets": false,
  "mixSetMinimumDuration": 1500.0   // READ-ONLY (see below)
}
```

**`POST /policy/set`** — sparse overlay; answers the same shape,
re-read from storage so the wire reports what actually persisted.

```json
{ "token": "…", "newMusicShare": 0.3, "excludeMixSets": true }
```

- `newMusicShare` distinguishes **absent** (leave the dial alone) from
  **explicit `null`** (turn the dial off). `null` ≠ `0.0` — zero is an
  active reorder that leads with owned music.
- `mixSetMinimumDuration` is never accepted: the stored policy hardcodes
  the default, so it's published for honest rendering, not as a knob.
- Takes effect at each station's next pool refill — no restart.

### Transparency (`taste`, `exclusions` capabilities)

**`POST /taste`** — body `{"token"}`. What the selection pipeline
believes about the owner's taste:

```json
{
  "libraryArtists": [ { "artist": "…", "score": 0.91 } ],   // top 10
  "libraryTags":    [ { "tag": "…",    "score": 0.66 } ],   // top 10
  "stations": [
    {
      "id": "UUID", "name": "…",
      "topAffinityArtists": ["…"],                          // top 5 seeds
      "counts": { "plays": 120, "saves": 4, "boosts": 2, "skips": 9 }
    }
  ]
}
```

**`POST /exclusions`** — body `{"token", "station": "UUID"?, "limit":
100?}` (station absent/null = all stations; limit clamps 1–500). The
mix-set filter's audit trail; rows with `"enforced": false` are the
shadow log — what the filter *would* remove while the toggle is off.

```json
{
  "exclusions": [
    {
      "id": 7, "stationID": "UUID", "artist": "…", "title": "…",
      "arm": "duration", "matchedText": null,
      "durationSeconds": 4210.0, "durationSource": "lastfm",
      "sourceKind": "lastFM", "sourceURL": null,
      "enforced": false, "everEnforced": false,
      "enforcedCount": 0, "hitCount": 3,
      "firstExcludedAt": 1755800000.0, "lastExcludedAt": 1755870000.0
    }
  ]
}
```

---

## Status codes

| code | meaning here |
|---|---|
| 200 | done (also idempotent no-ops: re-start, re-stop) |
| 201 | station created |
| 204 | CORS preflight |
| 302 | legacy `/stream.aac` redirect |
| 400 | body didn't decode / station id didn't parse |
| 403 | not the owner (`"listener mode"`) — throttled on repetition |
| 404 | unknown route; no current track; artwork/stream not found |
| 409 | knob doesn't exist on this station kind |
| 410 | station id parses but the station no longer exists — drop it from the view |
| 413 | JSON body over 64 KB |
| 422 | validation: unknown kind, no tags, empty name, missing API key |
| 500 | start failure, history store unavailable, recording failure |
| 503 | catalogue unavailable (no music folder) — capable but unusable, don't hide the panel |

## Verification

`scripts/verify-control-plane.sh` exercises this surface end-to-end from
outside (through Cloudflare) after every deploy: `/health` capabilities,
`/auth` in both directions, then a throwaway-station
create → list → update → start → stop → delete round trip with
trap-based cleanup. `scripts/verify-listening.sh` covers the audio path.
