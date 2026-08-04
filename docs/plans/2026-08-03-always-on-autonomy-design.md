# Always-On Autonomy — Design Doc

**Date:** 2026-08-03
**Status:** Draft, for review

## Problem

Ratbat today is a radio Jonas has to DJ. Every capability from the last two releases — faceted stations, taste intelligence, prefetch reliability — only runs while a human has clicked "Start Broadcast" on the Mini. In practice the station is usually offline: the tunnel is down (Cloudflare 530), `radio.jonasjohansson.se` is dead, and none of the discovery machinery is discovering anything.

Jonas's stated end-state is four goals:

1. Automatic new-music discovery, like a Discover Weekly.
2. Anytime listening with genre channels, like NTS Radio.
3. ♥ a track → it's downloaded and stored. *(Already built — the ♥ save flow.)*
4. Playlists/folders created automatically. *(Already built — dated mix-tape folders per station per day.)*

Goals 3 and 4 shipped. Goals 1 and 2 don't need new intelligence — they need an **autonomy layer**: the app starting its own broadcasts, listeners choosing channels without Jonas involved, and discovery running on a schedule instead of only during listening.

One idea considered and rejected up front: "start broadcasting when someone visits the URL." Structurally impossible with the current architecture — the tunnel comes up only when the first station starts (`RadioBroadcaster.startBroadcast`, first-station bootstrap), so with nothing broadcasting the visit dies at Cloudflare's edge (530) and never reaches the Mini. There is no request to react to. Auto-start-at-launch achieves the same felt result without inverting the tunnel lifecycle.

## Why always-on is cheap

The expensive half of always-on already exists. The encode loop is listener-gated (`RadioBroadcaster.runEncodeLoop`): after the first track, it parks in `awaitListener` until someone connects, and unblocks within ~5s of a connection. A live-but-unlistened station resolves exactly one track and then sleeps — no yt-dlp, no Last.fm calls, no cache growth. The standing cost of a 24/7 station is one cloudflared connection and an idle process on a Mac Mini that's already awake.

## Goals

- Ratbat on the Mini comes up broadcasting at launch, with no interaction. Combined with the existing LaunchAgent (docs/mac-mini-setup.md §5), a reboot ends with the radio publicly live.
- A listener opening `radio.jonasjohansson.se` sees the live channels and can play one in the browser — NTS-style channel choice, no app required.
- Once a week, a Discover folder appears in the library containing ~20 taste-scored tracks Jonas hasn't heard, without anyone listening to anything.

## Non-goals (v1)

- Visit-triggered wake. Rejected above.
- iOS listener changes. The picker page is plain web; the iOS app keeps its current tune-in flow.
- Any auth on the picker page. Same public posture as `/now.json` — the broadcaster only knows live stations, so idle library entries can't leak.
- Listener accounts / per-listener taste. The taste profile stays Jonas's.
- Multi-machine broadcasting or tunnel failover. Explicitly single-machine (see Risks).
- Fixing the ~5s `awaitListener` join latency. Acceptable for v1; noted as a follow-up.

## Architecture

Three pieces, deliberately independent — each ships alone.

### 1. Auto-start (goal 2's "anytime")

No concept of a default station exists today (no `autoStart`/`isDefault` anywhere in the codebase). Smallest sufficient version:

```swift
// BroadcastPreferences addition:
@Published public var autoStartSlugs: [String] = []   // station slugs to start at launch
```

Slugs, not `Station.ID`s: stations persist in `.ratbat-stations.json` *next to the library* and sync across machines via Drive, while preferences are per-machine `UserDefaults`. Slugs are stable across the two stores and human-readable in `defaults read`.

Launch hook in `RootView` (which already owns broadcaster construction and station loading): after `StationManager` finishes its initial load, start every station whose slug is listed:

```swift
.task {
    // after stations load…
    for station in stations.all where preferences.autoStartSlugs.contains(station.slug) {
        await radio.startBroadcast(station: station)
    }
}
```

The first `startBroadcast` brings up the HTTP listener and the tunnel exactly as a manual click does — no tunnel-lifecycle changes. Unknown slugs are skipped silently (station may live on another machine's library); a station that fails its dependency guards logs and bails exactly as today.

**Idle economics:** each auto-started station resolves one track eagerly (the "user just hit play" path) and then parks. N auto-started stations cost N track resolutions at launch, then nothing. Worth stating in Settings copy: an auto-start list of 5 genre channels is a perfectly reasonable steady state.

### 2. Channel picker page (goal 2's "like NTS")

> **Revision (2026-08-03, same day):** this section was written in ignorance of `ratbat.fm` — a separate repo already deployed at `ratbat.jonasjohansson.se` (GitHub Pages) that does the picking and playing: station cards as mini-players off `/now.json`, one-at-a-time playback, an API-base resolver mapping `ratbat.<domain>` → `radio.<domain>`. The gap was only ♥/skip, which shipped to it the same day (`ratbat.fm` commit `069b788`). The embedded-page idea below is superseded; it survives only as a possible LAN-fallback "nothing on air" page, which is optional. Phase B is effectively done.

The data plane already exists and needs **zero new endpoints**: `/now.json` returns *all* currently-broadcasting stations with current track and listener counts, `/events` (SSE) pushes a fresh snapshot on every track change, and each station streams at `/stream/<slug>.aac`. What's missing is only a face: `GET /` currently falls through to 404.

Add one route to the broadcaster's HTTP server: `GET /` serves a single static HTML page (embedded in the binary as a Swift string constant, same pattern as the SSE header block — no resource-bundle loading, nothing to misplace in the app copy step).

The page, in full:
- Renders a card per station from the initial `/now.json` fetch: station name, current artist — title, listener count.
- One `<audio>` element; clicking a card points it at `/stream/<slug>.aac`. One stream at a time — it's a radio, not a mixer.
- Subscribes to `/events` for live now-playing updates; falls back to polling `/now.json` every 15s if SSE fails.
- ~~thumbs~~ Buttons wired to the existing `POST /like` and `POST /skip` (both already CORS-open). This quietly closes the loop on goal 3 for remote listening: ♥ from a phone browser saves the track into the library on the Mini.
- No framework, no build step. Hand-written HTML/CSS/JS in one string. Target: under 150 lines.

`GET /` when nothing is broadcasting can't be reached from outside (tunnel down → 530 at the edge), but serve a "nothing on air" page anyway for LAN visitors — it doubles as a health check that distinguishes "Ratbat down" from "no stations live".

### 3. Weekly Discover drop (goal 1)

A scheduled job that runs the existing discovery pipeline without a listener, and lands its output in the library via the goal-4 machinery that already works.

New actor `DiscoverDrop` (RatbatCore, macOS-gated — it needs the resolver stack):

1. **Candidate pool.** For each source station in a configured list (default: all Last.fm/Bandcamp stations), run the station controller's existing pool-refill path — faceted filters, precision verification, taste scoring, explore↔comfort dial all apply for free.
2. **Dedupe against history.** Drop anything with a row in `HistoryStore` (already played on air) and anything whose artist+title matches the indexed library (already owned). The point is *new to Jonas*, enforced with data we already have.
3. **Select.** Take the top ~20 across sources by taste score, capped at 2 per artist so one prolific artist can't fill the drop.
4. **Resolve.** Feed each through `TrackResolver` (bounded concurrency, reuse of the transient cache and its new 10 GB LRU cap).
5. **Land.** Copy into `{musicFolder}/260810 Discover/` — the same dated-folder convention as ♥ saves (`RadioBroadcaster.saveCached`), so the library indexer picks it up as a playlist with zero new code, and Drive syncs it to every machine.
6. **Record.** Insert history rows marked with a new `source` discriminator (see Schema) so next week's dedupe sees this week's drop, and so drop tracks don't masquerade as on-air plays in taste scoring.

**Scheduling:** in-process timer, not launchd. The app already runs 24/7 on the Mini under the LaunchAgent; a task that checks `lastDiscoverDrop` in preferences hourly and fires when >7 days have passed is simple, survives sleep/wake, and needs no second deployment artifact. If the app was down at the due time, it fires on next launch.

**Failure posture:** the drop is best-effort. Any track that fails to resolve is skipped, not retried; a drop with 12 of 20 tracks still lands. A fully-failed drop (network down) logs and re-arms for the next hourly check — never a partial folder deleted or rewritten.

## Schema + config changes

`HistoryStore`:
```sql
ALTER TABLE history ADD COLUMN source TEXT NOT NULL DEFAULT 'broadcast';
-- 'broadcast' | 'discover'
```
Same idempotent-ALTER migration pattern as the taste-intelligence columns. Taste scoring's play-through and save signals filter on `source = 'broadcast'`; a Discover track earns behavioral weight only after it's been played or ♥'d like anything else.

`BroadcastPreferences`:
```swift
@Published public var autoStartSlugs: [String] = []
@Published public var discoverDropEnabled: Bool = false
@Published public var lastDiscoverDrop: Date? = nil
```

## UX surfacing

- **Station detail views** gain an "Auto-start on launch" toggle (writes the slug into `autoStartSlugs`). One toggle per station beats a separate management list.
- **Settings → Broadcast** shows the auto-start list read-only, with the idle-economics one-liner.
- **Settings → Discover** (new): enable toggle, source-station checklist, last-drop timestamp, "Run now" button (the same code path as the timer — essential for testing the whole feature without waiting a week).
- **Picker page** is its own UX surface; see §2.

## Phasing

Phase A — auto-start. Smallest change, unblocks "anytime", makes the URL permanently live. Ship first and alone.

Phase B — channel picker page. Pure listener-side; touches only the HTTP server.

Phase C — Discover drop. The only new subsystem. Depends on nothing in A/B, but ships last because its output is only reachable *by radio* once A exists (the folder is reachable in the library regardless).

## Risks + open questions

- **The tunnel becomes the Mini's, permanently.** Only one machine can serve it; today "whoever starts first wins". With the Mini auto-starting at login, the MacBook can effectively never broadcast without stopping the Mini first. This is a real workflow change and should be accepted deliberately — it's also arguably the point (retire the MacBook as a broadcaster, per docs/mac-mini-setup.md §4's "pick one and retire the other").
- **The dropout fix is still unproven.** Auto-start makes broadcasting automatic; if the prefetch fix hasn't actually eliminated the stalls, it makes a broken stream automatic. Gate Phase A's merge on one real listening session against the deployed build.
- **yt-dlp exposure concentrates.** A weekly 20-track drop plus always-on stations means steady automated YouTube traffic from one IP. The existing per-resolve throttles apply, but Discover should run with low concurrency (2–3) and jittered scheduling rather than a thundering Sunday-midnight herd.
- **Disk growth moves from cache to library.** The 10 GB LRU cap protects the transient cache, but Discover output lands in the *library* (and syncs to Drive) — ~20 tracks/week ≈ 2 GB/year. Acceptable; note it in the Settings copy. No auto-pruning of Discover folders in v1: deleting music Jonas may not have heard yet is worse than the disk cost.
- **Auto-start races the library load.** Stations load from the music folder; if the folder is a cloud mount that's slow to come up after reboot, station load may complete before Drive has hydrated the audio files. Generative stations don't care (they resolve remotely); playlist stations might open files that are placeholder stubs. Mitigation: auto-start only after the first successful library index, and accept that a cold-boot playlist station may stall until Drive settles.
- **Open question — how many channels?** Auto-starting every station vs. a curated few changes launch cost (one eager track-resolve each) and picker-page clutter. v1 leaves it to the per-station toggle; revisit if the list grows past ~6.
- **Open question — Discover source weighting.** Equal weight per source station vs. weighting by that station's ♥-rate. v1: equal weight, revisit with data.
- **Decided (2026-08-03) — multi-listener skip semantics.** `/skip` and `/next` are global: one shared stream, any listener advances the track for everyone. Accepted for the realistic listener count (Jonas + friends); the web player shows "N listening" when N > 1 so people know they're not alone. Quorum-based skipping would need per-listener identity the server deliberately doesn't have — build it only if the audience ever outgrows friends-and-family, not before.
