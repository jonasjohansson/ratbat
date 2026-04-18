# Ratbat

Personal radio for the Apple ecosystem. macOS + iOS. Build genre-faceted stations from your local library, Last.fm tags, NTS tracklists, or Bandcamp tag feeds — broadcast them over the internet as a real streaming radio via Cloudflare Tunnel.

---

## What it does

- **Library** — point it at a music folder (local or Google Drive) and it indexes it. Loose tracks surface in a "Loose Tracks" playlist; folder-per-album layout is handled automatically.
- **Generative stations** — four kinds:
  - **Playlist station**: pre-shuffled queue derived from one of your playlists.
  - **NTS station**: scrapes NTS Radio shows matching your tags and streams their tracklists through an on-demand resolver.
  - **Last.fm station**: seeds from Last.fm's tag top-tracks, with popularity tiers + artist-tag precision verification.
  - **Bandcamp station**: pulls recent or popular releases from Bandcamp tag feeds — the long-tail underground source.
- **Faceted queries** — genre × era (year range) × region (ISO country codes), AND'd across facets. MusicBrainz supplies authoritative era + region data. The classic "temporal tags leaked into genre results" bug (`2000s` Brazilian samba in a techno station) is structurally impossible under this model.
- **Taste intelligence** — a local `TasteProfile` derives your preferences from library listening + per-station ♥-saves and biases station selections toward what you actually like. No data leaves your Mac.
- **Broadcasting** — every live station serves a `http://localhost:<port>/stream/<slug>.aac` endpoint. Pair with Cloudflare Tunnel to get a stable public URL like `https://radio.example.com`.
- **Listening** — iOS companion app tunes into a broadcaster's URL. CarPlay + AirPlay supported.

## Status

Personal-use project. Works well for Jonas. No guarantees of stability, compatibility, or release cadence — this is optimised for "what I want to listen to," not "what the world needs." Feel free to fork.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode command-line tools
- Homebrew
- `xcodegen`, `ffmpeg`, Python 3.10+ (via Homebrew)
- (Optional) A Cloudflare account + a domain for public broadcasting

## Install

```bash
# Homebrew deps
brew install xcodegen ffmpeg python@3.14

# Build + install
./install.sh
```

`install.sh` regenerates the Xcode project via `xcodegen`, builds `RatbatMac` in Debug with signing off, copies the resulting `.app` bundle to `/Applications/Ratbat.app`, and launches it. First run takes ~30-60 s while the Python resolver venv bootstraps inside Application Support.

## First-launch setup

1. **Pick a music folder.** A local folder or a cloud-synced one (Google Drive, Dropbox, iCloud). Stations persist next to the library as `.ratbat-stations.json` — so pointing two machines at the same cloud folder shares stations automatically.
2. **(Last.fm only)** Paste a Last.fm API key in Settings → Last.fm. Register one free at <https://www.last.fm/api/account/create>.
3. **(Optional)** Adjust broadcast port + bitrate in Settings → Broadcast. Defaults: port 18000, max quality.

## Mac Mini always-on deployment

See [`docs/mac-mini-setup.md`](docs/mac-mini-setup.md) for running Ratbat as a LaunchAgent on a dedicated Mac Mini — useful if you want your radio online 24/7 without tying up your main machine. Covers Cloudflare Tunnel setup, sleep-prevention, and the shared-drive station sync trick.

## Project layout

```
RatbatCore/        # Shared framework (macOS + iOS)
  Radio/           # Station + broadcaster primitives
    LastFM/        # Last.fm API client + station controller
    NTS/           # NTS scrape + station controller
    Bandcamp/      # Bandcamp discover API client + station controller
    MusicBrainz/   # MB enrichment client (era + region)
    FacetedQuery   # Shared faceted-query + filter pipeline
  Taste/           # Local taste profile (library + history-derived)
  Player/          # AAC encoder + ring buffer + audio decoder
  Views/           # SwiftUI views (macOS-only ones gated)
  Tests/           # XCTest
RatbatMac/         # macOS app shell
RatbatIOS/         # iOS listener
Vendor/
  cloudflared/     # Bundled cloudflared binary (used for tunneling)
  spotify-downloader-bundle/  # Python wrapper around yt-dlp + ytmusicapi
docs/              # Design + implementation plans
install.sh         # One-command build-and-install
```

## Architecture

- **Station kinds** are a sum type (`Station.Kind` enum) with three cross-platform cases + one macOS-only Bandcamp case. Each station persists just the *config* to disk; the controller state (pool, history, resolver) is reconstructed on every broadcast start from the config.
- **Broadcasting** is a per-port HTTP server (`RadioBroadcaster`) that encodes each station to AAC at a configurable bitrate and serves it at `/stream/<slug>.aac`. Multiple stations share one port via the slug route.
- **Resolution** — generative stations produce `(artist, title)` pairs that `TrackResolver` turns into playable local files via `yt-dlp` (for YouTube Music matches) or direct URL (for Bandcamp releases, which carry their origin URL through the pipeline).
- **Faceted pipeline** — a stateless `FacetedPipeline` namespace holds the shared post-fetch stages (tag-mode intersection, library/artist exclusions, MB era filter, MB region filter). Both Last.fm and Bandcamp controllers call into it from their own actor context.

## Third-party components & attributions

Ratbat integrates several external services and libraries. Thanks to:

- **[Last.fm](https://www.last.fm/api)** — track + artist tag data. Their public API (`tag.getTopTracks`, `artist.getTopTags`) powers Last.fm stations. API key required.
- **[MusicBrainz](https://musicbrainz.org/)** — open music metadata encyclopedia. Their public `ws/2/` API supplies authoritative first-release-date + artist area/country data for era + region filters. Data is CC0; we rate-limit to 1 req/sec per their [etiquette](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting).
- **[Bandcamp](https://bandcamp.com/)** — Bandcamp stations read from the undocumented `/api/discover/3/get_web` JSON endpoint used by their own Discover page. No affiliation. Please support the artists you discover there directly.
- **[NTS Radio](https://www.nts.live/)** — NTS stations scrape show pages and tracklists for generative seeding. No affiliation. Please listen to NTS directly — they are doing the actual curation work.
- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** — downloads audio for resolved tracks. Public-domain equivalent (Unlicense).
- **[ytmusicapi](https://github.com/sigma67/ytmusicapi)** — YouTube Music search for the resolver. MIT.
- **[ffmpeg](https://ffmpeg.org/)** — audio format handling invoked by yt-dlp. LGPL.
- **[cloudflared](https://github.com/cloudflare/cloudflared)** — Cloudflare Tunnel client, bundled in the app for one-click public broadcasting. Apache 2.0.
- **[Homebrew](https://brew.sh/)** — build-time dependency installation.
- **SF Symbols** — Apple.

This project is not endorsed by or affiliated with any of the above.

## Contributing

This is a personal project; PRs are unlikely to be merged unless they fix a clear bug. If you fork it for your own use, that's exactly what it's for. For significant changes, open an issue first so you don't waste time on something that won't land.

## License

MIT. See [`LICENSE`](LICENSE).
