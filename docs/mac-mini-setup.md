# Running Ratbat on a Mac Mini

Goal: Ratbat runs on the Mini, serves audio at `http://localhost:18000`, Cloudflare Tunnel exposes it at `radio.jonasjohansson.se`. The Mini becomes the always-on broadcaster so any laptop / phone can tune in without needing the main Mac awake.

All commands are meant to be run on the Mini. SSH in from the main Mac (`ssh mini.local` or whatever you've named it) if you'd rather type from there.

---

## 1. Prereqs

```bash
# Xcode command-line tools (provides the Swift toolchain + xcodebuild).
# If Xcode.app is already installed, this step is a no-op.
xcode-select --install

# Homebrew, if it's not there yet.
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Build + runtime deps.
brew install xcodegen ffmpeg python@3.14
```

Python 3.14 specifically — some of the resolver's transitive deps (spotapi in particular) use `X | None` type syntax that requires 3.10+. `python@3.14` is what the session shipped with; any 3.10+ Homebrew Python also works.

---

## 2. Clone + build

```bash
mkdir -p ~/GitHub/org/jonasjohansson
cd ~/GitHub/org/jonasjohansson
git clone https://github.com/jonasjohansson/ratbat.git
cd ratbat
./install.sh
```

`install.sh` generates the Xcode project, builds the Mac target, stops any running Ratbat instance, copies the .app to `/Applications/Ratbat.app`, and launches it. First run takes ~30-60s while the Python venv bootstraps inside Application Support.

---

## 3. First-launch configuration

When Ratbat launches the first time you'll see the folder-picker screen.

1. **Pick a music folder.** If your library lives on Google Drive, point it at `~/Library/CloudStorage/GoogleDrive-<email>/My Drive/Music` (or wherever you keep it). Stations persist in `{musicFolder}/.ratbat-stations.json`, so **pointing at the same Drive folder from the Mini makes the stations you created on the main Mac appear automatically**.

2. **Paste your Last.fm API key.** Open Settings (⌘,) → Last.fm → paste the key. Same key you used on the main Mac; register a new one at https://www.last.fm/api/account/create if you need a fresh one.

3. **Pick broadcast quality + port** (Settings → Broadcast). Default 128 kbps / 44.1 kHz / port 18000 is what the Cloudflare Tunnel expects — leave these alone unless you know you want different.

---

## 4. Cloudflare Tunnel

The tunnel ID `85530a41-6981-49b1-a809-9df59d1d6156` on Jonas's Cloudflare account routes `radio.jonasjohansson.se` → `localhost:18000`. The *credentials* for that tunnel are a JSON file on disk; the Mini needs its own copy.

**From the main Mac, scp the cloudflared state over:**

```bash
# Run on the main Mac
scp -r ~/.cloudflared mini.local:~/
```

That copies `config.yml` + `<tunnel-id>.json`. Ratbat's bundled cloudflared binary reads from `~/.cloudflared` automatically when a station starts broadcasting — no extra config needed on the Mini side.

**Important:** only one machine can serve a tunnel at a time. The first to come online wins; the other will fail to connect. To avoid a race, stop broadcasting on the main Mac before starting a broadcast on the Mini (or just pick one and retire the other).

---

## 5. (Optional) Always-on: make Ratbat auto-start at login

macOS's standard way is a LaunchAgent. Create one per user that runs at login:

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/se.jonasjohansson.ratbat.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>se.jonasjohansson.ratbat</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>/Applications/Ratbat.app</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/se.jonasjohansson.ratbat.plist
```

`KeepAlive` is deliberately off — if Ratbat crashes we'd rather surface the crash than silently loop it. Toggle to `true` if you want auto-respawn.

Remove later with:
```bash
launchctl unload ~/Library/LaunchAgents/se.jonasjohansson.ratbat.plist
rm ~/Library/LaunchAgents/se.jonasjohansson.ratbat.plist
```

---

## 6. (Optional) Prevent the Mini from sleeping

A sleeping Mac can't serve a tunnel. In System Settings → Energy (or `pmset` from the terminal), disable display + disk sleep when plugged in. Minimum:

```bash
sudo pmset -c sleep 0 displaysleep 10 disksleep 0
```

`sleep 0` keeps the Mac fully awake on AC power.

---

## 7. Verify

From any laptop / phone:

```bash
open https://radio.jonasjohansson.se
```

or paste that URL into a browser / VLC. If a broadcast is running on the Mini, you should hear audio. If it's `502 Bad Gateway`, the tunnel is up but nothing is broadcasting — start a station in Ratbat on the Mini.

From the Mini itself:

```bash
# Watch live. Note the absolute path: `log` is a zsh builtin, and calling
# it bare gets you the builtin, which silently answers nothing at all.
/usr/bin/log stream --predicate 'subsystem == "se.jonasjohansson.ratbat"' --level info --style compact
```

`log stream` only shows what happens *while you watch*, which is no use
for "the radio went dark at some point last night". For that, read back:

```bash
# What the radio actually did, after the fact. Default level is enough:
# lifecycle is logged at .notice and failures at .error, both of which
# the unified log persists. --info/--debug are NOT persisted, so asking
# for them tells you nothing about last night.
/usr/bin/log show --last 12h --style compact \
  --predicate 'subsystem == "se.jonasjohansson.ratbat"'

# Narrow to a surface:
#   category == "tunnel"               cloudflared lifecycle + why it died
#   category BEGINSWITH "broadcaster"  listener, stations, encode loop
```

Test runs log to `se.jonasjohansson.ratbat.tests`, so the predicate above
is the radio only. That split exists because a two-hour sample once held
23,056 lines under the production subsystem, every one of them from
`xctest` and none from the running app.

The outside-in verdict history — one line per check, including the
periodic watcher if you've loaded it — is plain text:

```bash
tail -20 ~/Library/Logs/ratbat-verify.log
```

---

## 8. Single writer: the Mini owns the station catalogue

The web player at ratbat.fm is now a control surface, not just a viewer:
a logged-in owner can create, edit, start, stop, and **delete** stations
from any browser. Every one of those mutations goes through the Mini's
HTTP API (`/stations/*` — see `docs/http-api.md`), which means the Ratbat
process **on the Mini** is the one writing `.ratbat-stations.json`.

That file is Drive-synced, and Drive handles exactly one writer well. So
the discipline is:

- **The Mini (the broadcasting machine) is the sole station writer.**
  Create and edit stations via the web control surface or in the app on
  the Mini itself — both are the same writer.
- **The MacBook creates and edits nothing.** Its app is read-only for
  stations: it picks up the Mini's changes on relaunch or via "Reload
  Library". There is deliberately no file watching — a half-synced Drive
  file mid-write is worse than a stale sidebar.
- Why this matters beyond conflict-copies: an **old build that edits**
  stations persists only the kinds it can decode, silently dropping any
  station kind it doesn't know from the shared file. Reading is safe
  (unknown kinds are skipped per entry); writing is lossy. Update all
  machines before creating stations of a newly added kind — and until a
  machine is updated, it must not mutate stations at all.
  This is not hypothetical any more: **Library Radio** (S4) is exactly
  such a kind. A pre-S4 build opening the shared file will read around a
  `libraryRadio` entry without harm, but the first station mutation it
  performs writes the file back without it. Update every machine before
  creating Library Radio stations (the behavior is pinned by
  `StationStoreTests.testUnknownKindEntrySurvivesReadButIsDroppedByWriteBack`).

### The passcode's blast radius, and rotating it

The shared owner passcode used to guard ♥/skip/boost. It now also guards
**delete** — one leaked passcode can empty the sidebar from anywhere on
the internet. The cheap guards are in place (typed-name confirmation on
the web, a growing delay on wrong-passcode attempts), but the real
mitigations are:

- **Rotation**: set a new passcode in Settings → Broadcast on the Mini,
  or clear the stored default with
  `defaults delete se.jonasjohansson.ratbat.mac ratbat.broadcast.ownerToken`
  — the app issues a fresh random token on next read. Either way every browser that knew the old
  passcode is locked out at once.
- **Undo**: `.ratbat-stations.json` is Drive-synced, so Drive's version
  history is the recovery path for a deleted station. Deletion is
  recoverable socially, not by the app.

---

## Gotchas

- **Launching Ratbat from `open`/Finder** (vs. from `install.sh`) inherits macOS's minimal GUI `PATH`, so yt-dlp won't find ffmpeg via `$PATH` lookup. The Python wrapper probes `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` explicitly to paper over this — as long as `ffmpeg` is in one of those three, you're fine regardless of how Ratbat was launched.
- **Drive sync races** — if stations on the main Mac and the Mini both try to write `.ratbat-stations.json` at the same time, Drive conflict-copies will pile up. The Mini is the only machine allowed to write stations — see §8 above.
- **Cloudflared binary path** — Ratbat bundles its own `cloudflared` inside `Ratbat.app/Contents/Resources`. No need to `brew install cloudflared`.
