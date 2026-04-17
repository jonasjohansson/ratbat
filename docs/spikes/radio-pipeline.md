# Spike: Radio pipeline (Task 3.2)

**Status:** complete
**Date:** 2026-04-17
**Scope:** end-to-end `[Track] → AVAudioFile → PCM → AAC/ADTS → HTTP → client`

## What we built

One `@MainActor` class, `RadioBroadcaster`, that owns four collaborating
helpers:

| Piece | Role |
| --- | --- |
| `AudioDecoder` | Opens a `Track` via `AVAudioFile`, reads PCM in 4096-frame chunks, resamples/rechannels to 44.1 kHz Float32 stereo via `AVAudioConverter`. |
| `AACEncoder` | Wraps `AVAudioConverter` in the other direction (PCM → AAC-LC at 128 kbps). Accumulates input, emits one 1024-sample ADTS frame at a time. |
| `ADTSHeader` | Builds the 7-byte ADTS header (value type, trivial). |
| `AACRingBuffer` | Lock-protected circular byte buffer of ~256 KB with async `read(from: cursor)` that suspends until the next write. New clients get a cursor at the live tail. |
| HTTP server | `NWListener` on a configurable port (default 8000). Per-client detached task reads request, sends HTTP 200 + `Content-Type: audio/aac`, then pumps ring buffer to the socket. |

## What worked

- **`AVAudioConverter` instead of the `AudioConverter` C API.** The task
  notes warned the raw C API would be a sinkhole, and skipping it saved
  us. `AVAudioConverter.convert(to:error:withInputFrom:)` has a clean
  Swift signature and does the same job. Both the PCM→PCM (resample/
  rechannel) and PCM→AAC paths use it.
- **`AVAudioCompressedBuffer` for reading out encoded packets.** The
  compressed buffer exposes per-packet offsets/sizes via
  `packetDescriptions`, which is exactly what we need to slap an ADTS
  header on each packet.
- **`Network.framework` `NWListener`.** Binding to port 8000 required no
  extra entitlements (we're unsandboxed). macOS did NOT prompt for
  firewall access when binding to `127.0.0.1` — loopback is free. First
  bind to `0.0.0.0` will prompt.
- **Ring buffer with per-client cursors.** Kept the design dead simple:
  monotonic "total bytes written" counter, modulo capacity for physical
  indexing. Readers suspend on a continuation; one wake-up on every
  write. Works fine for a handful of listeners.
- **End-to-end integration test.** `testBroadcastProducesAACStream`
  runs the full pipeline against the bundled fixture M4As, fetches the
  HTTP stream with `URLSession.bytes`, verifies HTTP 200 +
  `Content-Type: audio/aac` + at least one `0xFFF*` ADTS sync word in
  the first 8 KB. Runs in ~7 seconds — that's the 2-second sleep to let
  the encoder produce bytes plus `URLSession`'s internal timing.

## What's gnarly

- **Swift 6 strict concurrency + AudioConverter callbacks.**
  `AVAudioConverter.convert`'s input closure is `@Sendable` in the Swift
  6 headers, which clashes with the natural pattern of mutating a "did
  I consume the input yet?" bool inside the closure. Solved with a
  `MutableBox` reference type marked `@unchecked Sendable` plus a
  `nonisolated(unsafe) let capturedPCM = pcm` dance. It's ugly but the
  converter invokes the closure synchronously from within its own call,
  so there's no actual data race.
- **`AVAudioPCMBuffer` is not `Sendable`.** Had to drop the initial plan
  of `AudioDecoder` being an actor. Hoping to pass buffers across
  actor boundaries trips "non-Sendable result can not be returned"
  diagnostics. Made `AudioDecoder` and `AACEncoder` both `final class
  @unchecked Sendable` — they live inside a single detached `Task`, so
  the sendability concern is moot in practice.
- **Ring buffer min-capacity clamp.** Original init allowed any
  capacity; clamped to 1024 to avoid a one-byte buffer pathological
  case. A unit test I wrote against `capacity: 16` silently got 1024
  instead, which masked the overflow semantics. Worth documenting on
  the public init.
- **`NWListener` state handler on a background queue.** Have to hop
  back to `@MainActor` to mutate published state; straightforward once
  you remember to do it.

## What's NOT in the spike

- Listener disconnect when the broadcaster is torn down mid-track:
  currently the detached serve-client task notices the connection
  failure on next `send` and exits, but the failure happens async and
  the app may see a momentary "listenerCount: 1" after `stop()`. For
  v1, `stop()` explicitly cancels tasks and closes connections, which
  fixes this — but you can still see it if the listener's write
  happens concurrently with `stop()`.
- **No CBR locking / rate control.** AAC is nominally 128 kbps but the
  encoder produces variable-size packets. We rate-limit the decode/
  encode loop via a fixed `Task.sleep(70 ms)` after each 4096-sample
  read. This is approximately real time but drifts. A listener that
  joins mid-broadcast sees a brief build-up of bytes then a slow
  starve-and-fill cadence. VLC buffering masks it.
- **Error recovery across queue items.** If a track fails to open,
  we skip it and advance. No retries, no user-visible surfacing
  beyond OSLog.
- **Listener rebinds on same port.** `allowLocalEndpointReuse = true`
  is set so quick stop/start cycles work without a `TIME_WAIT` pause.

## Latency observations

The integration test waits 2 seconds after `start(queue:)` before
connecting, and the first bytes show up essentially instantly once the
HTTP request is parsed. So the observed latency from "broadcast is
running" to "client sees first AAC byte" is effectively zero —
dominated by the 2-second prebuffer, which is a test choice, not a
pipeline constraint. A real client (VLC) will do its own ~2-3 second
buffering on top, which is standard for HTTP audio streams.

## Manual VLC test

Not run as part of the spike (no audio library loaded in this session).
To repro:

1. Build and run `RatbatMac`.
2. Point it at a folder of audio files.
3. Right-click a playlist, "Create Station from this".
4. Click the antenna icon in the window toolbar.
5. Watch the sidebar caption under the station name flip to
   `http://localhost:8000/stream.aac`.
6. `open -a VLC http://localhost:8000/stream.aac` (or File → Open
   Network in VLC).
7. Audio should start within 3 seconds.

To validate the stream without VLC:

```sh
ffprobe -timeout 2000000 http://localhost:8000/stream.aac
```

Expected: `Input #0, aac, from 'http://...'` with a stream listed as
`Stream #0:0: Audio: aac (LC), 44100 Hz, stereo, fltp, 128 kb/s`.

## Recommendations for Task 3.3 (productionization)

1. **Move `MutableBox` / `nonisolated(unsafe)` shenanigans behind a
   cleaner abstraction.** The decoder + encoder each re-invent the
   same "convert one PCM buffer to one output packet" pattern; consider
   wrapping `AVAudioConverter` in a small helper that hides the
   `@Sendable` dance.
2. **Tighten rate control.** Replace the fixed `Task.sleep(70 ms)` with
   a pacing loop driven by output byte count vs. elapsed wall time.
   Goal: never let the ring buffer fill more than ~2s ahead of real
   time, so listeners joining mid-way see a fresh live tail without the
   "starve and fill" jitter.
3. **Multiple stations.** `RadioBroadcaster` currently hard-codes one
   broadcast at a time. Productionizing means multiple concurrent
   stations (one per active station), each on its own port or at least
   its own URL path. Refactor so the listener routes on the path
   (`/stream/<station-id>.aac`) and keeps a ring buffer per station.
4. **Persistent listener count.** The `listenerCount` is updated per
   client connect/disconnect. Consider hooking it into the Station
   model so the UI can show "N listening" per station.
5. **Metadata in the stream.** Icecast-style ICY title updates
   (`icy-title` HTTP header plus inline metadata every N bytes) so VLC
   shows "Now playing: …". Nice-to-have for v2.
6. **Non-44.1kHz source files.** Decoder resamples via
   `AVAudioConverter` — should handle anything AVAudioFile can open,
   but we've only tested with the 44.1 kHz fixtures. Add coverage for
   48 kHz and mono sources in Task 3.3.
7. **Error UI.** The `error` published property is currently only
   surfaced via the `.help()` toolbar tooltip. For production, show
   a proper alert when the listener fails to bind or the encoder
   errors.
8. **Task cancellation cleanliness.** The `stop()` path cancels the
   broadcast task, but the detached per-client tasks take one more
   `send()` round-trip to notice. Not a bug but worth tightening with
   explicit cancellation before `connection.cancel()`.

## Files touched

- `RatbatCore/Radio/RadioBroadcaster.swift` (new, ~280 LoC)
- `RatbatCore/Radio/AudioDecoder.swift` (new)
- `RatbatCore/Radio/AACEncoder.swift` (new)
- `RatbatCore/Radio/AACRingBuffer.swift` (new)
- `RatbatCore/Radio/ADTSHeader.swift` (new)
- `RatbatCore/Tests/RadioBroadcasterTests.swift` (new, 8 tests)
- `RatbatCore/Views/RootView.swift` (toolbar button wiring)
- `RatbatCore/Views/PlaylistsSidebarView.swift` (URL caption when
  broadcasting)
