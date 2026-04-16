# Johanssound

Personal music app for the Apple ecosystem. Downloads Spotify playlists as local files, plays them in a Winamp-style UI, and broadcasts what you're listening to as a personal HTTP radio station.

**Status:** design → implementation (Phase 0)

## What it does

1. **Download** — paste Spotify URL, get m4a files (via YouTube Music match)
2. **Play** — native Apple media player for your local library
3. **Broadcast** — whatever is playing locally is simultaneously streamed on a public URL

## Platforms

- macOS (SwiftUI) — full app: library, downloader, player, broadcaster
- iOS (SwiftUI) — listener: tune into a stream URL, CarPlay, AirPlay

## Design

See `../skynet/wiki/projects/johanssound.md` for the full design doc.

## Implementation

See `docs/plans/` for phased implementation plans.
