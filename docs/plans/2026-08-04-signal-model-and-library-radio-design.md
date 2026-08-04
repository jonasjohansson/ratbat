# Signal Model (Keep vs Steer) + Library Radio — Design Doc

**Date:** 2026-08-04
**Status:** Draft, for review — build together with Phase C of the always-on doc

## Problem

Two conflations surfaced in the same day of real listening:

1. **♥ means two unrelated things.** "Keep this file" (archival) and "steer the radio toward this" (navigational) share one button. Jonas named the failure modes directly: a gorgeous ambient outlier belongs in the collection but shouldn't drag the techno channel ambient-ward; a track can be *exactly the right direction* without being a keeper. The negative side already got this split — 👎 (never again) vs ⏭ (not now) — the positive side didn't.
2. **No station is seeded by the library itself.** Every generative station starts from hand-picked tags. "Discover based on everything I have" — the closest thing to a true personal Discover Weekly — requires the taste profile to *choose the seeds*, not just rank candidates inside a human-drawn boundary.

Both land in `TasteProfile.score` and both feed Phase C (the weekly Discover drop), so they build as one unit.

## Goals

- Split the positive signal: ♥ = archive (mild affinity), **boost** = "more of this" (strong affinity + immediate steering).
- Boost acts *now*: it re-seeds the station's similar-artist expansion and triggers a pool refill — pointing the radio, not rating the past.
- A **Library Radio** station kind with no tag field: seeds derive from the taste profile's library layer and drift as the library drifts.
- Phase C's Discover drop ranks boost > save > play-through.

## Non-goals (v1)

- Retroactive reclassification of existing ♥s. History stands; old saves keep their current weight.
- Per-track (rather than per-artist) steering. The profile's unit of affinity is the artist; boosting a track boosts its artist and neighborhood. Track-level embeddings are a different project.
- Un-boost UI. A boost decays like everything else (same recency machinery); explicit retraction isn't worth a button.
- Boost on the iOS stub or Mac detail views beyond the minimum (web player + one Mac menu item first).

## The signal model, stated once

| Signal | Gesture | Meaning | Profile effect | Immediate effect |
|---|---|---|---|---|
| **Boost** | `+` next to ♥ (web), context menu (Mac) | "More of this" | Strong artist affinity, weight **above** save | Re-seed similar-artist expansion from this artist; trigger pool refill |
| **♥** | Heart | "Mine now" | Mild affinity | Download to library (or affinity row if owned) |
| Play-through | (passive) | "Didn't object" | Weak, recency-decayed | — |
| **⏭** | Skip-forward | "Not right now" | None | Advance |
| **👎** | Thumbs-down | "Never again" | Hard blacklist | Advance |

Scoring weights (revising the taste-intelligence doc's formula):

```
score = 0.35 * boost_affinity        // graduated, recency-decayed, NEW
      + 0.20 * save_affinity         // was 0.35 — ♥ demotes to archival-mild
      + 0.20 * playthrough_affinity
      + 0.15 * library_match
      + 0.10 * tag_match
      - 1.00 * skip_penalty          // unchanged hard blacklist
```

Both affinities feed the same saturating curve; boost simply saturates higher and decays on the same half-life. Exact constants are a starting point for tuning, not a contract.

## Architecture

### 1. Schema

```sql
ALTER TABLE history ADD COLUMN boosted_at REAL;   -- NULL = never boosted
```

Same idempotent-ALTER migration as prior columns. Boost without a history row (owned/playlist tracks) reuses the ♥-affinity mechanism shipped in `71d1542`: insert a row, stamp `boosted_at` instead of relying on `saved`.

### 2. `TasteProfile`

New `boostAffinity(artist:stationID:)` mirroring `savedEntries`-based affinity but reading `boosted_at IS NOT NULL`, with the weight table above. One new HistoryStore query (`boostedEntries(forStation:limit:)`).

### 3. Steering (the point of the feature)

`POST /boost` (same request/CORS shape as `/like`) →
1. Stamp `boosted_at` on the current track's row (or insert one, owned-track style).
2. Tell the station controller to **re-seed**: the boosted artist goes to the front of the similar-artist expansion queue and a pool refill is scheduled. The refill machinery exists; this adds a "seed override" entry point on the controller protocol. Stations mid-track finish the track — steering affects the pool, not the needle.

Wire: `200 {"status":"boosted"}`. Playlist stations: fully supported (that's half the point — steer *from* your own records).

### 4. Library Radio (self-seeding station)

New config, no `genreTags` field:

```swift
public struct LibraryRadioStationConfig: Codable, Sendable {
    public var exploration: Double = 0.5
    public var excludeOwnedLibrary: Bool = true   // discovery by default
    public var seedCount: Int = 8                  // top-N profile tags/artists per refill
}
```

Controller derives seeds **per refill** from the live profile: top `seedCount` tags (library layer) + top boosted/saved artists (behavioral layer), fetches per-seed via the Last.fm client (Bandcamp joins when multi-source lands), then the standard pipeline. Because seeds re-derive every refill, the station drifts with the library and with boosts — boost something tonight, Library Radio digs there tomorrow. This is the radio-form of Phase C; the drop is the folder-form of the same query.

### 5. UI

- **Web:** a `+` button beside ♥ on the active card. Note: `+` = "more like this", filled state ~10s then reverts (it's a command, not a state). Four actions is the ceiling — anything more and the card is a mixer.
- **Mac:** station context menu gains "More Like This" for the current track; detail views later.
- **Add-station:** "New Library Radio…" in the + menu — one dial, two fields, no tags.

## Phasing (one build session each)

1. **Boost** — schema, scoring, `/boost`, re-seed hook, web `+`. Ships alone; immediately useful on every existing station.
2. **Phase C Discover drop** (already designed) — now ranking boost > save. Build after boost so week one's drop reflects steering.
3. **Library Radio** — the config, seed derivation, add-view. After boost so behavioral seeds exist.

## Risks + open questions

- **Weight rebalance changes every station's feel at once.** ♥-heavy stations get mellower steering overnight. Mitigation: constants in one place, a log line per refill showing the top-5 scored with component breakdown, so "why is it playing this" is answerable.
- **Boost-refill cost.** A refill per boost could hammer sources if someone boosts five tracks in a minute. Debounce: one scheduled refill per station per few minutes; boosts within the window fold into it.
- **Open question — does ⏭ stay signal-free forever?** Heavy ⏭ on an artist is arguably weak negative signal. Deferred: the whole point of ⏭ is that it's safe to press without consequences; adding weight would re-poison it. Revisit only with evidence.
- **Open question — boost half-life.** Same 30-day half-life as play-throughs, or shorter (steering is intent-in-the-moment)? v1: same, one constant to change.
