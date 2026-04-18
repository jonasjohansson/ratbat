# Faceted stations, Bandcamp source, MusicBrainz enrichment — design

_2026-04-18_

## Motivation

Current generative stations (NTS, Last.fm) take a flat `tags: [String]` list with a single tag-mode toggle (`any` / `all`). This is structurally too weak for the queries users actually want — things like "techno from 90s Japan" or "newly released dungeon synth". Two concrete failures today:

1. **Exaltasamba leaks into a Techno station.** Station tagged `[techno, 1990s, 2000s]` under TagMode `.any` builds a union pool including every mega-scrobbled 1990s/2000s artist. The precision filter at `LastFMStationController.swift:230` treats temporal tags (`2000s`) as co-equal proof of genre match, so Brazilian pagode passes verification.
2. **"Newly released music" is unreachable.** Last.fm's `tag.getTopTracks` returns all-time listener-ranked tracks; recent-but-unscrobbled releases don't exist in Last.fm's data until weeks after release. Decade tags are too noisy to fix this.

Both symptoms have the same root cause: temporal and regional information lives in the same flat bucket as genre, with the same set semantics.

## Goals

- Support **faceted queries**: genre × era × region, AND'd across, OR'd within.
- Add **Bandcamp** as a third generative source — same mental model as Last.fm, better coverage of recent underground releases.
- Add **MusicBrainz** as an enrichment layer for authoritative era + region data.
- Fix the Exaltasamba class of bug as a side-effect of the redesign.
- Preserve existing station configs on disk with zero user-visible migration step.

## Non-goals

- Label/artist follow-list ("play everything on Tri Angle Records"). Different product shape; punt to v2.
- Spotify integration (no viable API access for streaming apps).
- SoundCloud integration (no public API signups since ~2019).
- Disk persistence of MusicBrainz caches (in-memory only in v1).

## Data model

One shared `FacetedQuery` struct, consumed by both upgraded-`LastFMStationConfig` and new-`BandcampStationConfig`:

```swift
public struct FacetedQuery: Hashable, Sendable, Codable {
    public var genreTags: [String]           // OR within; required (>=1)
    public var yearMin: Int?                 // AND; optional
    public var yearMax: Int?                 // AND; optional
    public var regions: [String]             // OR within; ISO 3166 alpha-2 codes
    public var tagMatch: TagMatch            // any | all, applies to genreTags only
    public var popularity: PopularityTier    // hits | middle | deepCuts, LastFM-only signal
    public var excludeOwnedLibrary: Bool
    public var excludedArtists: Set<String>
}

public struct LastFMStationConfig: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var query: FacetedQuery
    public var shufflePool: Bool
}

public struct BandcampStationConfig: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var query: FacetedQuery
    public var sort: BandcampSort            // .date (default) | .pop
}

// Station.Kind gains:
case bandcamp(config: BandcampStationConfig)
```

**Design points:**

- **Temporal becomes its own facet.** `2000s` stops being a string tag; it becomes a numeric year range. This kills the Exaltasamba bug directly: temporal info can no longer masquerade as genre proof.
- **Regions = ISO alpha-2** codes. MusicBrainz artist `area` already returns these. UI uses `Locale.current.localizedString(forRegionCode:)` to display "Japan" for storage value `"JP"`.
- **Popularity stays** on `FacetedQuery` but is Last.fm-specific; Bandcamp controller ignores it (no listener count on Bandcamp). Cheap and honest.
- **Precision mode leaves the config.** With era+region as first-class facets, precision's old job (catching mis-tagged artists) is largely subsumed. An implicit `.verified` precision runs inside the Last.fm controller against the pure-genre `genreTags` array — now safe because no temporal pollution.

## Migration

- `StationStore.currentVersion` stays at **1**. No disruptive bump.
- `LastFMStationConfig.init(from:)` is extended to handle both shapes:
  - If `query` key present → decode new shape.
  - Else → decode legacy keys (`tags`, `yearMin`, `yearMax`, `tagMode`, `popularity`, `excludeOwnedLibrary`, `excludedArtists`) and hydrate a `FacetedQuery`. `regions` defaults to `[]`.
- Encoder writes the new shape only. Next save upgrades the file in place.
- Bandcamp is brand-new; no migration concerns.

This pattern matches what was already used for the filter-suite addition in `LastFMStationConfig.swift:100` — zero risk to existing stations on the Google Shared Drive.

## MusicBrainz client

New `MusicBrainzClient` actor, sibling to `LastFMClient`:

```swift
public actor MusicBrainzClient {
    public init(userAgent: String, session: URLSession = .shared)
    public func firstReleaseYear(artist: String, title: String) async -> Int?
    public func countryCode(forArtist artist: String) async -> String?
}
```

- Base URL: `https://musicbrainz.org/ws/2/` · `fmt=json`.
- **User-Agent required** — `Ratbat/1.0 (jns.johansson@gmail.com)`. MB throttles hard without it.
- Rate limit: 1 req/sec public. Actor-serialized gate awaits until 1.05s since the last request (50ms safety margin).
- Endpoints:
  - `firstReleaseYear` → `GET /recording/?query=artist:"X" AND recording:"Y"&limit=1&fmt=json` → top hit's `first-release-date[0..<4]`.
  - `countryCode` → `GET /artist/?query=artist:"X"&limit=1&fmt=json` → top hit's `area.iso-3166-1-codes[0]`.
- Caching: actor-scoped `[String: Int?]` and `[String: String?]` in-memory. Negatives cached (`.some(nil)`) so we don't waste quota re-asking. No disk persistence in v1.
- Fail-open: any error (network, parse, 503) → return `nil`. Controller always keeps unknowns (rationale: MB coverage on Bandcamp bedroom-producer tracks is ~50%; fail-closed would starve Bandcamp stations).

## Controller pipeline

Two separate controllers remain — `LastFMStationController`, new `BandcampStationController`. Shared post-filter stages extracted into a `FacetedPipeline` namespace so the bug-fixing logic lives in one place.

Common candidate type for shared stages:

```swift
public struct SourceCandidate: Sendable {
    public let artist: String
    public let title: String
    public let resolvedURL: URL?         // Bandcamp sets; Last.fm nil
    public let listenersHint: Int?       // Last.fm sets; Bandcamp nil
    public let matchedTags: Set<String>
}
```

`resolvedURL` is the key architectural field — it lets the resolver short-circuit YouTube-Music matching when the source already knows the audio URL (Section on resolver below).

**Pipeline stages** (per refill, cheap → expensive):

| # | Stage | LastFM | Bandcamp | Location |
|---|-------|:---:|:---:|---|
| 1 | Seed fetch | `tag.getTopTracks` | scrape `/tag/<slug>` | Per-controller |
| 2 | Tag mode (any/all) | ✓ | ✓ | `FacetedPipeline` (shared) |
| 3 | Popularity tier | ✓ | — | Per-controller (LastFM) |
| 4 | Precision verification | ✓ | — | Per-controller (LastFM) |
| 5 | Library + artist exclusions | ✓ | ✓ | `FacetedPipeline` |
| 6 | MB era filter | ✓ | ✓ | `FacetedPipeline` |
| 7 | MB region filter | ✓ | ✓ | `FacetedPipeline` |
| 8 | Taste score + wildcard shuffle | ✓ | ✓ | `FacetedPipeline` |

**Ordering rationale:**
- Cheap exclusions (stage 5) run **before** MB lookups (stages 6–7). No point burning 1 req/sec on an artist the user already owns.
- Era filter before region filter — year misses are more common than region misses for typical queries; dropping year-mismatches first shrinks the region-lookup set.

**Samba bug, post-redesign:** "Techno + 1990s + Japan" becomes `genreTags: ["techno"]`, `yearMin: 1990, yearMax: 1999`, `regions: ["JP"]`. Exaltasamba fails stage 1 (not tagged "techno"); even if they snuck through they'd fail stage 7 (MB reports area = BR, not JP). Double defense.

## Bandcamp client + resolver

New `BandcampClient` actor, sibling to `LastFMClient` / `MusicBrainzClient`.

**Tag page URL:**
```
https://bandcamp.com/tag/<slug>?sort_field=<date|pop>&page=<n>
```
Paginate up to 5 pages per tag (~50-100 releases). Default sort is `date` for Bandcamp stations — that's the whole point of adding it.

**Multi-tag composition:** Bandcamp tag pages are single-tag. Same pattern as Last.fm — fetch per tag, intersect in stage 2. This is the reason stage 2 moves into `FacetedPipeline` rather than being LastFM-specific.

**Scrape mechanism:**
- Tag page HTML embeds a JSON blob — `<div id="pagedata" data-blob="...">` with URL-encoded JSON containing `items[]` (`artist`, `title`, `tralbum_url`, `release_date`).
- Extract blob via Scanner/regex, JSON-decode, pluck fields. No SwiftSoup / HTML parser dependency.
- **Acknowledged risk**: Bandcamp occasionally restructures. Mitigation: saved fixture HTML in `BandcampClientTests`, so template drift trips a test rather than silently stopping the station.

**What we extract per release:**

```swift
public struct BandcampRelease {
    let artist: String
    let title: String
    let releaseURL: URL   // bandcamp.com/track/... or /album/...
    let releaseDate: Date?
}
```

No direct stream URL extraction at scrape time — **yt-dlp handles it** (see resolver).

**Rate limiting / etiquette:**
- Actor-serialized, 500ms between fetches. User-Agent: `Ratbat/1.0 (jns.johansson@gmail.com)`.
- Scrape failure for one tag → log, return `[]`, other tags proceed. All tags fail → `throw Error.noTracksForTags(...)`.

**Resolver integration:**
- `SourceCandidate.resolvedURL` carries the Bandcamp release URL forward.
- `TrackResolver` gets a direct-URL shortcut: if `candidate.resolvedURL != nil`, skip YouTube Music matching and pass the URL straight to yt-dlp. yt-dlp's built-in `BandcampIE` does the release-page → mp3 resolution natively.
- Falls into the same cache-quick-download path as the YouTube flow. AACEncoder / AACRingBuffer see no difference.

## UI

Two separate Add sheets — matches the NTS/Last.fm convention. `AddLastFMStationView`, new `AddBandcampStationView`. Both compose a shared `FacetedQueryEditor` subview.

**Shared `FacetedQueryEditor`:**
- **Genre** — curated palette (toggle grid) + free-text "Add tag..." field. Palette gives a start; free-text is where Bandcamp's long-tail scene tags live (`dungeon synth`, `outsider house`, `hauntology`).
- **Era (optional)** — two numeric TextFields, From / To. Actually enforced now.
- **Region (optional)** — multi-select chip picker. Popover backed by `Locale.isoRegionCodes`, displayed via `Locale.current.localizedString(forRegionCode:)`. Storage = ISO "JP", display = "Japan".

**Source-specific fields** (below the shared editor):
- Last.fm: Popularity tier picker, Tag mode segmented (any/all). Precision is gone from UI.
- Bandcamp: Sort picker (Date / Popularity), default Date.

**Sidebar icon** for Bandcamp stations: a new SF Symbol, pick at implementation time (`waveform` or `cassette.fill` are candidates).

## Error handling summary

| Failure | Policy |
|---|---|
| MB network/parse error | `MusicBrainzClient` returns `nil`; pipeline keeps candidate (fail-open). |
| MB 503 rate-limit | Same as network error. Serialized actor absorbs the next request anyway. |
| Bandcamp scrape failure for one tag | Log at info, return `[]`, other tags proceed. |
| Bandcamp scrape failure for all tags | `throw Error.noTracksForTags(...)`. |
| Bandcamp HTML structure drift | Parse tests with saved fixtures catch it in CI; runtime returns `[]`. |
| Post-filter pool empty | Existing behavior preserved — `throw Error.noTracksForTags` + surface to UI. |

**OSLog cardinality logging** at every pipeline stage boundary (pattern already established in `LastFMStationController`). When a user reports "my Japan-techno station is silent", the logs show which stage ate the candidates.

## Testing strategy

- `FacetedPipelineTests` — era / region filters with a stub MB client; any/all intersection; exclusion logic; ordering of stages.
- `MusicBrainzClientTests` — parse-only, fixture JSON for `recording` + `artist` search responses.
- `BandcampClientTests` — parse-only, fixture HTML for a tag page; structure-drift detection.
- `LastFMStationConfigTests` — extended with:
  - Round-trip for the new faceted shape.
  - Decode from legacy shape → assert populated `FacetedQuery` matches expectations (migration assurance).

## Open follow-ups (not in this design)

- **Label follow-list** station kind. Different product; punt to v2.
- **Unified "New Generative Station" sheet** that replaces the separate Add-sheets. Revisit once the UX patterns settle.
- **Disk-persisted MB cache**. In-memory rebuilds are fine for v1; revisit if startup latency becomes noticeable.
- **Temporal-tag validator in existing `LastFMStationConfig` decoding** — migration moves `2000s`-style tags out of `genreTags` and into `yearMin`/`yearMax` automatically. Currently the migration carries them through verbatim; an enhancement would strip them.
