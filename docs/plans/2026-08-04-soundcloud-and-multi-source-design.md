# SoundCloud Source + Multi-Source Stations — Design Doc

**Date:** 2026-08-04
**Status:** Draft, for review

## Problem

The three generative sources have a coverage hole shaped exactly like Jonas's library. Sampling it: Soulwax remixes, DJ Tennis remixes, Maceo Plex remixes, Gerd Janson dubs, bootleg edits — **remix and edit culture is the center of the collection**, and none of the sources reach it. Last.fm doesn't index unreleased edits; Bandcamp doesn't carry bootlegs; NTS only surfaces what a curator played on a show. SoundCloud is where that music actually lives.

Separately, adding a fourth source makes a structural smell unignorable: **station creation is source-first, but Jonas thinks genre-first** ("New NTS Station… / New Last.fm Station… / New Bandcamp Station… / New SoundCloud Station…" forces choosing the backend before the music). A proper "90s Techno" channel today needs four parallel stations, one per source, which quadruples sidebar rows and channel-picker cards. This doc covers both: the new source (Phase 1, ships fast) and the multi-source station that absorbs it (Phase 2, the shape the product wants).

## Goals

- A SoundCloud-backed generative station kind: per-genre discovery of recent tracks, edits, and remixes, run through the same faceted filters and taste scoring as every other source.
- Resolution via the existing `TrackResolver` direct-URL shortcut — no YouTube-Music matching for tracks that already have a canonical URL.
- Phase 2: one station = one faceted query drawing from **all configured sources**, interleaved and dedup'd — "90s Techno" as a single channel, not four.

## Non-goals (v1)

- SoundCloud user auth, likes-sync, or scrobbling. Discovery reads public charts only.
- SoundCloud Go / paywalled or preview-only tracks — skipped, not worked around.
- Retiring the existing three kinds in Phase 1. Phase 2 migrates them; Phase 1 adds a parallel fourth, mechanically.
- Playlist stations joining the multi-source pool (the "seed with my playlist, expand with discovery" idea stays future work — noted, not designed here).

## Phase 1 — SoundCloud as a fourth source

Mechanical mirror of the Bandcamp pattern (~660 lines across four files: client 205, source 34, config 33, controller 386). Same directory shape: `RatbatCore/Radio/SoundCloud/`.

### 1. `SoundCloudClient` (actor, macOS-gated)

Discovery reads the per-genre charts SoundCloud's own web app uses:

```
GET https://api-v2.soundcloud.com/charts
    ?kind=new_hot            // or `top`
    &genre=soundcloud:genres:techno
    &client_id=<scraped>
    &limit=100
```

`kind=new_hot` is the discover feed — recent tracks ranked by momentum, which is exactly the "music that didn't exist last month" signal. Returns track objects with `title`, `user.username` (artist), `permalink_url`, `created_at`, `duration`, `policy`.

**The client_id problem, stated honestly:** SoundCloud closed public API registration years ago. Every SoundCloud tool (including yt-dlp) scrapes a `client_id` from the web app's JS bundles and refreshes it when it expires. The client does the same: fetch `soundcloud.com`, regex the script URLs, extract `client_id`, cache it in memory, re-scrape on the first 401/403. This is the most breakage-prone code in the app and gets a dedicated error path (`Error.clientIDUnavailable`) that surfaces in the station UI rather than failing silently. Filter `policy == "ALLOW"` tracks only — `SNIP` (Go-only 30s previews) are skipped at the client, not discovered-then-failed at the resolver.

### 2. `SoundCloudStationConfig` + `Station.Kind.soundcloud`

Config mirrors `BandcampStationConfig`: `FacetedQuery` + a `Sort` enum (`newHot` / `top`). New `case soundcloud(config: SoundCloudStationConfig)` in `Station.Kind`, macOS-gated exactly like `.bandcamp` — `StationStore`'s per-station decode-or-drop already handles the cross-platform wire-format asymmetry (that's finding-audited: `StationStore.swift` drops undecodable entries rather than losing the file).

### 3. `SoundCloudStationController` through `FacetedPipeline`

Same stages as Bandcamp: fetch chart page(s) → faceted filters (genre from the chart itself; era/region via MusicBrainz enrichment where it resolves — **expect low MB hit-rates for bootlegs/edits**, which is fine: the pipeline's fail-open unknown-count logging already covers this) → taste scoring with wildcard reservation → pool.

One SoundCloud-specific filter worth having from day one: **duration bounds** (default: keep 2–15 min). SoundCloud charts mix tracks with hour-long DJ sets and 30-second loops; a radio station wants neither by default. Config-exposed so a "mixes only" station is one toggle away later.

### 4. Resolution

`TrackResolver`'s direct-URL path (built for Bandcamp) takes `permalink_url` straight to yt-dlp, which supports SoundCloud natively. No new resolver code — the `sourceURL != nil` branch already skips YouTube-Music matching.

### 5. UI

`AddSoundCloudStationView` mirrors the Bandcamp add-view: `FacetedQueryEditor` + sort picker + duration bounds. Toolbar menu gains the fourth item — accepted Phase 1 ugliness that Phase 2 deletes.

## Phase 2 — multi-source stations

The refactor the last three design conversations kept arriving at: **a station is a faceted query plus a dial, and sources are checkboxes, not identities.**

### Shape

```swift
public struct MultiSourceStationConfig: Codable, Sendable {
    public var query: FacetedQuery
    public var exploration: Double            // the existing dial
    public var sources: Set<SourceKind>       // .lastFM, .bandcamp, .nts, .soundcloud
    public var shufflePool: Bool
}
// Station.Kind gains: case multi(config: MultiSourceStationConfig)
```

### Pool assembly

Each enabled source contributes candidates through its existing client + the shared `FacetedPipeline`; the controller merges:

1. **Fetch concurrently** per source, fail-open per source (one source erroring logs and contributes nothing — a SoundCloud client_id outage must not silence the Last.fm half of the pool).
2. **Dedup** on normalized `artist|title` (the `HistoryStore.normalize` rules), keeping the candidate whose source ranks higher for *acquisition quality*: Bandcamp > SoundCloud > Last.fm/NTS resolution via YouTube — a direct-URL candidate beats a search-matched one for the same track.
3. **Score + interleave** through the taste profile exactly as today — scoring is already source-agnostic. Source *balance* is deliberately not enforced in v1: if taste + facets mean Bandcamp wins 70% of a station's slots, that's the right answer, not a bug. Revisit only if a station degenerates to a single source in practice.

### Migration

Existing generative stations decode as they are — no forced migration. The add-flow creates `.multi` stations only; the three single-source add-views retire from the + menu (the kinds stay decodable indefinitely). A station detail affordance "Convert to multi-source" copies a legacy config's query into a `.multi` with that one source checked — opt-in, reversible by just not doing it.

### UX (the payoff)

One "New Station…" item. The sheet opens with `FacetedQueryEditor` — genre first — then the explore dial, then four source checkboxes framed by what they *mean*: canonical picks (Last.fm) · fresh underground (Bandcamp) · curator taste (NTS) · edits & remixes (SoundCloud). The sidebar and the ratbat.fm channel row show one card per *musical identity* instead of one per backend.

## Phasing

- **Phase 1 (SoundCloud kind):** client + config + controller + add-view + tests. Ships alone; useful immediately as the edits/remixes channel. Estimated at Bandcamp-scale: a focused session.
- **Phase 2 (multi-source):** new kind + merge/dedup + one-item add-flow + convert affordance. Depends on Phase 1 only in that SoundCloud should exist to be a checkbox. This is faceted-stations-scale work: design review first, then its own implementation plan.

## Risks + open questions

- **client_id brittleness is the defining Phase 1 risk.** Mitigations: scrape-and-cache with refresh-on-401, a surfaced error state, and yt-dlp as the canary (when yt-dlp's SoundCloud support breaks, ours has too). Accept that this source will need occasional patching; that's the tax on reaching unlicensed music.
- **Chart quality varies wildly by genre.** `new_hot` for `techno` is strong; niche genres can be thin or spam-heavy. The taste profile's precision filters help; the duration filter helps; beyond that, Jonas's 👎 is the moderation tool. Watch before adding heavier filtering.
- **MusicBrainz era/region facets will mostly miss for edits/bootlegs.** Fail-open is correct (an unfindable bootleg shouldn't be dropped for lacking a release year), but a station with tight era/region facets + SoundCloud-heavy sources will behave more loosely than the same facets on Last.fm. Document in the add-view, don't fight it.
- **Dedup false negatives across sources.** "Artist — Track (Soulwax Remix)" vs "Artist — Track (Soulwax Remix) [FREE DL]" won't collide on normalized artist|title. v1 accepts occasional near-duplicates; fuzzy matching is a later refinement (same stance as the taste profile's exact-artist matching).
- **Open question — does `.multi` absorb playlist seeds?** "My playlist + discovery around it" keeps coming up (goal-4 machinery meets discovery). Deferred: it changes the pool model (owned tracks as pool members, not just filters) and deserves its own thinking.
- **Open question — per-source explore dials?** One dial per station or one per source-within-station. v1: one per station; more knobs need evidence they're wanted.
