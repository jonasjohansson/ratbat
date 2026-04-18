# Taste Intelligence — Design Doc

**Date:** 2026-04-18
**Status:** Design approved, ready to plan

## Problem

The Last.fm station kind ships with tag-based discovery but has two problems:

1. **Tag contamination.** Last.fm tags are user-contributed; pop/eurodance tracks pollute genre queries like "techno". First broadcast surfaced *Groove Coverage — Poison* in a techno station — a genuine eurodance track that got into the techno pool because one user mis-tagged it.
2. **No personalization.** Every station plays the same "top tracks for tag X", regardless of who Jonas is. A Spotify-lite radio that learns from his library + behavior would make discovery feel personal rather than generic.

The fix is a local intelligence layer that (a) filters out clear mis-matches before they reach the pool, and (b) scores remaining candidates against a locally-derived taste profile so the station plays things that are both **surprising** (new to Jonas) and **relevant** (on-genre + aligned with his actual taste).

No Last.fm user auth, no external accounts. Everything derives from his local library + behavior inside Ratbat.

## Goals

- Filter candidates hard to remove mis-tagged tracks, blacklisted artists, already-owned tracks (when user asks).
- Score remaining candidates by taste-profile affinity, mixing library-derived and behavioral signals.
- Surface a dislike (skip) button alongside the existing ♥ save so the profile gets both positive and negative signal.
- Keep 20% of pool slots as "wildcards" so stations don't converge to boring predictability.

## Non-goals (v1)

- Year-range enforcement. Last.fm can't reliably surface year per track; MusicBrainz cross-ref is deferred.
- Similar-artist graph expansion (`artist.getSimilar`). Nice but not core — defer to v2.
- Track-to-track similarity flow (Pandora-style). Defer to v2.
- Last.fm user-auth / scrobbling. Explicitly excluded by user direction.
- Cross-station learning sharing. Per-station behavior stays scoped; library signal is the only shared layer.

## Architecture

Four new/modified pieces:

### 1. Filter suite (`LastFMStationConfig` + pool refill)

Hard constraints applied during pool assembly in `LastFMStationController.refillPool()` before scoring. All filters live on the config so they persist with the station.

Config additions:
```swift
public enum TagMode: String, Codable, Sendable {
    case any    // match ANY selected tag (union — current behavior)
    case all    // match ALL selected tags (intersection, narrower)
}

public enum PopularityTier: String, Codable, Sendable {
    case hits       // top 10% by listeners
    case middle     // 10-50th percentile (default)
    case deepCuts   // bottom 50% — underground / discovery
}

public enum PrecisionMode: String, Codable, Sendable {
    case off        // trust Last.fm tag hits (fast, noisy)
    case verified   // require artist's top-5 tags to include the query tag (default)
    case strict     // require artist's top-3 tags to include the query tag
}

// Added to LastFMStationConfig:
var tagMode: TagMode = .any
var popularity: PopularityTier = .middle
var precision: PrecisionMode = .verified
var excludeOwnedLibrary: Bool = false
var excludedArtists: Set<String> = []
```

Filters applied in order during pool refill:
1. `tag.getTopTracks` for each configured tag → raw candidates.
2. `TagMode` union vs intersection.
3. `PopularityTier` — partition by listener count, keep the asked tier.
4. `ExcludeOwnedLibrary` — drop artists that appear in Jonas's indexed library.
5. `ExcludedArtists` — drop the user-blacklisted artist names.
6. **Artist tag verification** (`PrecisionMode`) — for each candidate artist, call `artist.getTopTags`; keep only candidates whose artist's top-N tags include the query tag. Cached forever per artist.

### 2. Taste profile (new, shared)

`TasteProfile` actor derives a local taste signal from two layers:

**Global / library-derived (passive, computed on library scan):**
- `topArtists: [String: Double]` — artist name → normalized score (track count / max)
- `topTags: [String: Double]` — genre/tag frequency from library's `genre` fields
- `yearDistribution: [Int: Int]` — rough histogram of release years

Stored in memory with a cached copy persisted to `~/Library/Application Support/Ratbat/taste-profile.json` so startup is instant and the profile survives library re-scans.

**Per-station behavioral (active, updated on ♥ / skip / full-play):**
- Recorded in an extended `HistoryStore` with new columns: `skipped: Bool`, `play_count: Int`, `skipped_at: TimeInterval?`.
- Each station's `nextTrack()` reads its own station-scoped behavioral profile.

Scoring function `TasteProfile.score(candidate, stationID) -> Double` in `[0, 1]`:
```
library_match = 1.0 if candidate.artist in library else 0.0
tag_match     = overlap(candidate.artist's top tags, library top tags)
save_affinity = 1.0 if artist has a ♥-saved track on this station
skip_penalty  = 1.0 if this track was skipped on this station

score = 0.30 * library_match
      + 0.25 * tag_match
      + 0.35 * save_affinity
      - 1.00 * skip_penalty   // hard blacklist — drops below 0, filtered out
```

Blacklist (`skip_penalty`) is applied as a hard post-filter: any candidate with `score < 0` is dropped. The remaining candidates are sorted high→low, top N kept.

### 3. Wildcard injection (anti-convergence)

After scoring, reserve ~20% of pool slots for unscored random picks from the filtered pool. Prevents the station from converging to the same handful of "top-scored" tracks when the profile gets opinionated.

Implementation: in `refillPool()`, split pool into `scored = top 80%` and `wildcard = random 20%` of remaining filtered tracks. Interleave so the encode loop sees a rotating mix.

### 4. Dislike button (new UI + handler)

New 👎 button alongside ♥ in both NTS and Last.fm detail views, and in the global `PlayerView` bar. Clicking it:
1. Records a skip in `HistoryStore` (`skipped=true, skipped_at=now`).
2. Advances the encode loop past the current track (via new `RadioBroadcaster.skipCurrent(stationID:)`).
3. Station-scoped: the skip influences THIS station's pool, not all stations.

## Schema changes

`HistoryStore` table additions:
```sql
ALTER TABLE history ADD COLUMN skipped INTEGER NOT NULL DEFAULT 0;
ALTER TABLE history ADD COLUMN skipped_at REAL;
ALTER TABLE history ADD COLUMN play_count INTEGER NOT NULL DEFAULT 0;
```

Migration handled in `HistoryStore.init()` with `CREATE TABLE IF NOT EXISTS` + idempotent `ALTER TABLE` per column (swallow "duplicate column" error on second run).

## UX surfacing

- **AddLastFMStationView** gains a "Filters" disclosure group with `TagMode`, `PopularityTier`, `PrecisionMode`, `ExcludeOwnedLibrary` toggles. Excluded artists managed separately (right-click artist card → "Exclude from this station").
- **Detail views** get a 👎 button next to ♥.
- **PlayerView** shows ♥ and 👎 side-by-side when a live broadcast is playing.
- **Settings** adds a "Taste profile" tab showing derived signals (read-only: your top 10 artists, top 10 tags, how many ♥/skip signals have been recorded). Transparency so Jonas knows what the profile thinks.

## Phasing

Phase 1 (this plan):
- Filter suite (TagMode, PopularityTier, PrecisionMode with artist verification, ExcludeOwnedLibrary).
- TasteProfile library layer + behavioral layer.
- Dislike button + HistoryStore migration.
- Wildcard injection.
- Hybrid scope (global library + per-station behavior).

Phase 2 (future):
- Excluded artists management UI.
- Similar-artist graph expansion.
- MusicBrainz year cross-reference.
- Settings "Taste profile" transparency tab.
- Cross-source scoring (let the profile influence NTS stations too).

## Risks + open questions

- **Artist-tag verification cost.** Cold pool refill adds ~10-20s on first use (one `artist.getTopTags` call per unique artist). Mitigated by forever-cache. UX: nothing plays during pool refill — listener-idle logic keeps this from running when nobody's tuned in.
- **Library match fidelity.** Artist-name match is string-exact (normalized). "The Prodigy" vs "Prodigy" would miss. Acceptable for v1; fuzzy matching is a later improvement.
- **Skip-to-delete ambiguity.** Currently no skip button anywhere. A "skip" without a dislike intent is ambiguous — is the user skipping because the track is bad, or because they're bored? v1 treats every skip as dislike; a "next" button (positive/neutral skip) can come later.
- **Taste-profile privacy.** Profile is local-only, stored under Application Support. No network leakage. But it's still an inferred behavioral signal — worth documenting what it contains if we add a transparency UI later.
