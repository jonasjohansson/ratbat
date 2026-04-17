# Ratbat MVP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native Apple app that downloads Spotify playlists as local files, plays them back in a Winamp-style UI, and broadcasts the playing audio as an HTTP radio stream reachable from any device.

**Architecture:** SwiftUI multi-platform (macOS + iOS) sharing ~80% of code. macOS target is the full product (library, downloader, player, broadcaster). iOS target is listener-only v1. Download leverages bundled `invzfnc/spotify-downloader` Python script as a subprocess. Radio broadcast taps the playing audio, re-encodes to MP3, serves on HTTP via `Network.framework`, and exposes a public URL via bundled `cloudflared`.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, AVFoundation, Network.framework, Python 3.12 embedded (`python-build-standalone`), `yt-dlp`, `ffmpeg` or `lame` for MP3 encoding, `cloudflared` (Go binary), Xcode 26+.

> **Note:** Opting into Swift 6 strict concurrency from the start. Will require `@MainActor` / `Sendable` discipline for AVFoundation and `Network.framework` work in later phases. Worth the friction — catches concurrency bugs at compile time.

**Design doc:** `../../skynet/wiki/projects/ratbat.md` (in the sibling skynet repo)

---

## Phase overview

| Phase | Goal | Outcome |
|---|---|---|
| **0** | Repo + Xcode scaffold | Buildable macOS + iOS targets, shared SwiftUI, CI-friendly |
| **1** | MVP local player | Pick a music folder, see library, play tracks with native controls |
| **2** | Downloader integration | Paste Spotify URL → m4a files appear in library |
| **3** | Radio streamer | Currently-playing audio is served as MP3 on `localhost:8000/stream.mp3` |
| **4** | Cloudflare Tunnel | Stream reachable on a public URL from phone/anywhere |
| **5** | iOS listener app | iPhone app that tunes into any stream URL, CarPlay-ready |
| **6** | Winamp skin | Chunky pixel UI + skin system |

Phases 0–1 are planned in detail below. Phases 2+ have acceptance criteria + high-level task lists — we replan them at the start of each phase with fresh knowledge.

---

## Phase 0 — Repo + Xcode scaffold

**Acceptance:** `Ratbat.xcodeproj` opens in Xcode, has macOS and iOS app targets, builds and runs a "Hello Ratbat" window on both. Shared SwiftUI code in a framework target.

### Task 0.1: Create Xcode project structure

**Files:**
- Create: `Ratbat.xcodeproj` (via Xcode UI or `xcodegen`)
- Create: `RatbatMac/RatbatMacApp.swift`
- Create: `RatbatIOS/RatbatIOSApp.swift`
- Create: `RatbatCore/RatbatCore.swift` (shared framework)
- Create: `RatbatCore/Views/HelloView.swift`

**Step 1: Install XcodeGen if not present**

```bash
brew install xcodegen
```

**Step 2: Create `project.yml`**

```yaml
name: Ratbat
options:
  bundleIdPrefix: se.jonasjohansson.ratbat
  deploymentTarget:
    macOS: "14.0"
    iOS: "17.0"
targets:
  RatbatCore:
    type: framework
    platform: [macOS, iOS]
    sources: RatbatCore
  RatbatMac:
    type: application
    platform: macOS
    sources: RatbatMac
    dependencies:
      - target: RatbatCore_macOS
  RatbatIOS:
    type: application
    platform: iOS
    sources: RatbatIOS
    dependencies:
      - target: RatbatCore_iOS
```

**Step 3: Create `RatbatCore/Views/HelloView.swift`**

```swift
import SwiftUI

public struct HelloView: View {
    public init() {}
    public var body: some View {
        Text("Hello Ratbat")
            .font(.largeTitle)
            .padding()
    }
}
```

**Step 4: Create `RatbatMac/RatbatMacApp.swift`**

```swift
import SwiftUI
import RatbatCore

@main
struct RatbatMacApp: App {
    var body: some Scene {
        WindowGroup {
            HelloView()
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}
```

**Step 5: Create `RatbatIOS/RatbatIOSApp.swift`**

Same as macOS but without the `frame` modifier.

**Step 6: Generate Xcode project and verify builds**

```bash
cd /Users/jonas/Documents/GitHub/org/jonasjohansson/ratbat
xcodegen generate
xcodebuild -scheme RatbatMac -destination 'platform=macOS' build
xcodebuild -scheme RatbatIOS -destination 'generic/platform=iOS Simulator' build
```

Expected: both builds succeed.

**Step 7: Commit**

```bash
git add .
git commit -m "chore: scaffold Xcode project with macOS, iOS, and shared Core targets"
```

### Task 0.2: Set up Swift Package Manager tests

**Files:**
- Create: `RatbatCore/Tests/HelloViewTests.swift`

**Step 1: Add a test target to `project.yml`**

```yaml
  RatbatCoreTests:
    type: bundle.unit-test
    platform: macOS
    sources: RatbatCore/Tests
    dependencies:
      - target: RatbatCore_macOS
```

**Step 2: Write a smoke test**

```swift
import XCTest
@testable import RatbatCore

final class HelloViewTests: XCTestCase {
    func testHelloViewExists() {
        let view = HelloView()
        XCTAssertNotNil(view)
    }
}
```

**Step 3: Run tests**

```bash
xcodegen generate
xcodebuild test -scheme RatbatCore -destination 'platform=macOS'
```

Expected: 1 test passes.

**Step 4: Commit**

```bash
git add .
git commit -m "test: add smoke test for shared Core module"
```

### Task 0.3: README + design doc link

**Files:**
- Modify: `README.md` (already created in Phase 0 prep)

Already done.

---

## Phase 1 — MVP local player

**Acceptance:**
- User launches the macOS app
- First launch: a "Pick music folder" prompt appears
- After picking a folder (e.g. `~/Music/Test/`), the library scans all `.m4a`/`.mp3` files recursively
- Tracks appear in a list, sortable by artist/title/album
- Double-click a track: it plays through the system output
- Play/pause button works. Seek works. Next/previous track works.
- macOS Now Playing integration shows current track, media keys work
- No downloading, no radio — pure local player

### Task 1.1: Music folder picker + persistence

**Files:**
- Create: `RatbatCore/Library/LibraryConfig.swift`
- Create: `RatbatCore/Views/FolderPickerView.swift`
- Create: `RatbatCore/Tests/LibraryConfigTests.swift`

**Step 1: Write failing test for `LibraryConfig` persistence**

```swift
func testLibraryConfigPersistsFolderURL() throws {
    let tempURL = URL(fileURLWithPath: "/tmp/ratbat-test")
    let config = LibraryConfig(defaults: UserDefaults(suiteName: "test")!)
    config.musicFolder = tempURL
    XCTAssertEqual(config.musicFolder, tempURL)

    let reloaded = LibraryConfig(defaults: UserDefaults(suiteName: "test")!)
    XCTAssertEqual(reloaded.musicFolder, tempURL)
}
```

**Step 2: Run test — should fail (type doesn't exist)**

```bash
xcodebuild test -scheme RatbatCore -destination 'platform=macOS' -only-testing:RatbatCoreTests/LibraryConfigTests/testLibraryConfigPersistsFolderURL
```

**Step 3: Implement `LibraryConfig`**

```swift
import Foundation

public final class LibraryConfig {
    private let defaults: UserDefaults
    private let key = "ratbat.musicFolder"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var musicFolder: URL? {
        get {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                            relativeTo: nil, bookmarkDataIsStale: &staleFlag)
        }
        set {
            guard let url = newValue else {
                defaults.removeObject(forKey: key)
                return
            }
            let data = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
            defaults.set(data, forKey: key)
        }
    }

    private var staleFlag = false
}
```

Note: security-scoped bookmarks are required for sandboxed macOS apps to retain folder access across launches.

**Step 4: Run test — should pass**

**Step 5: Commit**

```bash
git add .
git commit -m "feat: add LibraryConfig with persisted security-scoped folder bookmark"
```

### Task 1.2: Library indexer (scan folder for audio files)

**Files:**
- Create: `RatbatCore/Library/Track.swift`
- Create: `RatbatCore/Library/LibraryIndexer.swift`
- Create: `RatbatCore/Tests/LibraryIndexerTests.swift`
- Test fixtures: `RatbatCore/Tests/Fixtures/library/`

**Step 1: Create test fixtures**

```bash
mkdir -p RatbatCore/Tests/Fixtures/library/ArtistA/AlbumA
# Copy any small .m4a files here for testing, or use AVAssetWriter to generate dummies
```

**Step 2: Write failing test**

```swift
func testIndexerFindsM4AFilesRecursively() throws {
    let fixture = Bundle.module.url(forResource: "library", withExtension: nil)!
    let indexer = LibraryIndexer()
    let tracks = try indexer.scan(folder: fixture)
    XCTAssertGreaterThan(tracks.count, 0)
    XCTAssertTrue(tracks.allSatisfy { $0.url.pathExtension == "m4a" })
}
```

**Step 3: Implement `Track` and `LibraryIndexer`**

```swift
public struct Track: Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
}
```

```swift
import AVFoundation

public struct LibraryIndexer {
    public init() {}

    public func scan(folder: URL) throws -> [Track] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])!
        var tracks: [Track] = []
        for case let url as URL in enumerator
        where ["m4a", "mp3", "aac", "flac"].contains(url.pathExtension.lowercased()) {
            if let track = try? await readMetadata(from: url) {
                tracks.append(track)
            }
        }
        return tracks
    }

    private func readMetadata(from url: URL) async throws -> Track {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.commonMetadata)
        let title = metadata.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue
            ?? url.deletingPathExtension().lastPathComponent
        let artist = metadata.first(where: { $0.commonKey == .commonKeyArtist })?.stringValue ?? "Unknown"
        let album = metadata.first(where: { $0.commonKey == .commonKeyAlbumName })?.stringValue ?? "Unknown"
        return Track(id: UUID(), url: url, title: title, artist: artist, album: album, duration: duration)
    }
}
```

**Step 4: Run test — should pass**

**Step 5: Commit**

```bash
git add .
git commit -m "feat: add LibraryIndexer that scans a folder for audio files and extracts metadata"
```

### Task 1.3: Library view — list of tracks

**Files:**
- Create: `RatbatCore/Views/LibraryView.swift`
- Create: `RatbatCore/ViewModels/LibraryViewModel.swift`

**Step 1: Implement `LibraryViewModel`**

```swift
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var tracks: [Track] = []
    @Published public var isLoading = false
    @Published public var error: Error?

    public init() {}

    public func load(from folder: URL) async {
        isLoading = true
        defer { isLoading = false }
        do {
            tracks = try LibraryIndexer().scan(folder: folder)
        } catch {
            self.error = error
        }
    }
}
```

**Step 2: Implement `LibraryView`**

```swift
public struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    @State private var folder: URL?

    public init() {}

    public var body: some View {
        VStack {
            if let folder {
                List(vm.tracks) { track in
                    HStack {
                        Text(track.title).bold()
                        Text(track.artist).foregroundStyle(.secondary)
                        Spacer()
                        Text(formatDuration(track.duration))
                    }
                }
                .task(id: folder) { await vm.load(from: folder) }
            } else {
                FolderPickerView(onPick: { self.folder = $0 })
            }
        }
    }
}
```

**Step 3: Wire up in `RatbatMacApp`**

```swift
WindowGroup { LibraryView().frame(minWidth: 800, minHeight: 600) }
```

**Step 4: Manual test — launch app, pick folder, see tracks**

**Step 5: Commit**

```bash
git add .
git commit -m "feat: add LibraryView showing scanned tracks with folder picker"
```

### Task 1.4: Audio player with AVPlayer

**Files:**
- Create: `RatbatCore/Player/AudioPlayer.swift`
- Create: `RatbatCore/Tests/AudioPlayerTests.swift`

Implement an `AudioPlayer` wrapping `AVQueuePlayer` with:
- `play(track:)`, `pause()`, `resume()`, `next()`, `previous()`, `seek(to:)`
- Publishes `currentTrack`, `isPlaying`, `progress` as `@Published`
- Tests: queue a fixture track, verify play/pause/seek work

### Task 1.5: Player view — play/pause/seek

**Files:**
- Create: `RatbatCore/Views/PlayerView.swift`

Bottom bar of the app window: current track info, play/pause, prev/next, seek slider. Wired to `AudioPlayer`.

### Task 1.6: Now Playing + Media Keys integration

**Files:**
- Create: `RatbatCore/Player/NowPlayingController.swift`

Use `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` to:
- Publish current track (title, artist, artwork, duration, elapsed) to OS
- Respond to play/pause/next/previous/seek from media keys and Control Center

Manual test: hit play in app, then use F8/F7/F9 keys on Mac keyboard → works.

### Task 1.7: Double-click to play, context menu, keyboard nav

**Files:**
- Modify: `LibraryView.swift`

Add:
- Double-click track → plays it
- Right-click → context menu (Play, Add to Queue, Show in Finder)
- Up/Down/Enter keyboard navigation

---

## Phase 2 — Downloader integration

**Acceptance:**
- User pastes a Spotify playlist URL into a field
- Progress UI shows "[MATCHING] track" → "[FOUND] track" → "[DOWNLOADING]" → done
- Downloaded `.m4a` files appear in the library folder, get indexed, show in library
- Works for a single song URL and a full playlist URL
- Failures are surfaced gracefully (one track failing doesn't abort others)

### High-level tasks

1. **Spike: embed Python in a macOS app.** Evaluate `python-build-standalone` (self-contained Python distribution). Goal: ship `python3` + `spotify-downloader` source + `yt-dlp` binary inside the `.app` bundle. Document findings in `docs/spikes/python-embedding.md`.
2. **Bundle spotify-downloader source.** Vendor the `core.py` from `invzfnc/spotify-downloader` into `Resources/spotify-downloader/`. Add `yt-dlp` + `ffmpeg` binaries to `Resources/bin/`.
3. **Write `DownloadService.swift`** — Swift class that spawns a Python subprocess running a small wrapper that calls `spotify-downloader.core.main()` with the user's URL, streams stdout/stderr back, parses the `[MATCHING]`/`[FOUND]` lines, emits events.
4. **Write tests** with a mock subprocess to verify event parsing.
5. **Build `DownloadView.swift`** — URL field, paste button, progress list.
6. **Wire into `LibraryView`** — after download, re-scan library folder.

### Open questions to resolve in spike

- Code signing + notarization with bundled Python / binaries
- Sandboxing: does the subprocess inherit sandbox restrictions? What entitlements do we need?
- Output location: Python script writes to the folder user picked in Phase 1

---

## Phase 3 — Radio streamer

**Acceptance:**
- When a track is playing in the app, an HTTP endpoint `http://localhost:8000/stream.mp3` serves the same audio
- Any HTTP audio client (VLC, Safari, iOS Music app with URL open) can tune in
- Stream continues seamlessly across track changes
- When playback is paused or no track is queued, a fallback (silence or shuffle) is served

### High-level tasks

1. **Spike: audio tap.** Can we tap `AVPlayer`'s output via `MTAudioProcessingTap` or route through `AVAudioEngine`? Pick the approach that lets us fork the PCM stream to both speakers and encoder.
2. **MP3 encoder.** Evaluate `lame` (via CLI subprocess or linked library) vs. `ffmpeg` vs. `AudioToolbox` (no MP3 in macOS, would need third-party). Pick one.
3. **HTTP server.** Use `Network.framework`'s `NWListener` to serve a chunked HTTP response with `Content-Type: audio/mpeg` and `icy-metadata` for track title.
4. **Ring buffer.** Small in-memory ring buffer so late-joining listeners get a ~2s head start instead of silence until the next encoder frame.
5. **Fallback playback.** When `AudioPlayer.isPlaying == false`, the broadcaster continues streaming from a shuffle queue (or silence with a "station idle" spoken marker).
6. **Listener count.** Track active HTTP connections, display in UI.

### Open questions

- Latency budget — MP3 encoder adds ~300ms; acceptable for a "radio" but not for live-synced listen-along
- Multi-listener scaling — how many listeners can one Mac handle? Probably 10+ easily
- Metadata in stream (ICY titles) — track name updates to listeners' players

---

## Phase 4 — Cloudflare Tunnel

**Acceptance:**
- On app launch, `cloudflared` starts as a subprocess
- A stable public URL is generated (or reused) and shown in UI
- The URL routes to `localhost:8000/stream.mp3`
- Phone on cellular can open the URL and hear the stream
- UI has a "Copy URL" button and shows a QR code for iOS app onboarding

### High-level tasks

1. Bundle `cloudflared` binary for `arm64` + `x86_64` Mac
2. `TunnelService.swift` — manages cloudflared lifecycle, parses its stdout for the generated URL
3. Persist the assigned URL (or use a named tunnel for stability)
4. QR code view generator

### Open questions

- Free trycloudflare URLs are ephemeral — do we want a named tunnel (requires Cloudflare account)?
- Latency / bandwidth through the tunnel — measure on a real cellular connection

---

## Phase 5 — iOS listener app

**Acceptance:**
- Install on iPhone via TestFlight
- Paste a stream URL (or scan QR from macOS app)
- Press play → audio streams, shows on lock screen, Control Center, CarPlay
- AirPlay works (stream → Sonos, HomePod, etc.)

### High-level tasks

1. `StreamListenerViewModel` — wraps `AVPlayer` playing a remote HTTP URL
2. URL input + QR scanner (using `AVCaptureMetadataOutput`)
3. `MPNowPlayingInfoCenter` on iOS (picks up ICY metadata from stream)
4. `MPRemoteCommandCenter` for lock screen / CarPlay controls
5. Background audio entitlement + `UIBackgroundModes` plist entry
6. CarPlay scene delegate (requires CarPlay entitlement — Apple review process)

---

## Phase 6 — Winamp skin

**Acceptance:**
- UI looks like Winamp, not default SwiftUI
- Optionally: can load classic Winamp `.wsz` skins (stretch goal)

### High-level tasks

1. Design one default pixel-chunky skin in Figma
2. Rebuild `PlayerView` + `LibraryView` using custom drawn views + pixel fonts + bitmap textures
3. (Stretch) Parse `.wsz` files (zip archives with BMPs + a config) and theme UI from them

---

## Development practices

- **TDD** for all non-UI logic (indexer, config, download parsing, audio player controls)
- **Manual / snapshot testing** for SwiftUI views
- **Frequent commits** — commit after every green test, every task
- **Small PRs** per task — easier to review, easier to revert
- **Document spikes** in `docs/spikes/` before committing to an approach
- **Keep `docs/plans/` current** — update this plan as we learn, don't let it go stale

## References

- Design doc: `../../skynet/wiki/projects/ratbat.md`
- Downloader upstream: `https://github.com/invzfnc/spotify-downloader`
- Jonas's fork / running: `/Users/jonas/Documents/GitHub/external/invzfnc/spotify-downloader/`
