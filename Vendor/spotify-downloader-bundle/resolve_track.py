#!/usr/bin/env python3
"""Ratbat track resolver.

Given (artist, title), find the best YouTube Music match and download
audio to the given output path. Prints JSON result on stdout.

Alternatively, when `--source-url` is supplied, skip the YouTube-Music
search entirely and hand the URL straight to yt-dlp. This is how
Bandcamp-origin candidates are resolved: their release page URL rides
through the candidate pool already, and yt-dlp's `BandcampIE` extractor
can fetch and decode the audio natively without any Ratbat-side scraping.

Usage:
    resolve_track.py --artist ARTIST --title TITLE --output PATH
    resolve_track.py --source-url URL --artist ARTIST --title TITLE --output PATH

Success (stdout):
    {"youtube_id": "dQw4w9WgXcQ", "matched_title": "..."}

    For `--source-url` mode the `youtube_id` field carries a
    synthetic identifier like `"bandcamp:<extractor-id>"` — there
    is no YouTube catalog entry to reference, and downstream
    consumers treat it as an opaque tag.

Failure (stderr, non-zero exit):
    Human-readable error; includes "NO_MATCH" if nothing found.

Exit codes:
    0 = success
    1 = no YouTube Music match
    2 = search failure (network / API error)
    3 = download failure
"""
import argparse
import contextlib
import io
import json
import os
import shutil
import sys

import query_variants
from ytmusicapi import YTMusic
from yt_dlp import YoutubeDL


def _locate_ffmpeg() -> str | None:
    """Return a directory containing `ffmpeg` + `ffprobe`, or None.

    When Ratbat.app is launched from Dock/Finder/LaunchServices, macOS gives
    it a minimal PATH that omits `/opt/homebrew/bin` and `/usr/local/bin`.
    yt-dlp's post-processor then fails with "ffmpeg not found". We probe the
    usual Homebrew/MacPorts locations ourselves and hand yt-dlp an explicit
    path via its `ffmpeg_location` option.
    """
    candidates = [
        "/opt/homebrew/bin",   # Apple Silicon Homebrew
        "/usr/local/bin",      # Intel Homebrew / MacPorts
        "/opt/local/bin",      # MacPorts alternate
    ]
    # Honor PATH first in case the user has a non-standard install.
    shutil_which = shutil.which("ffmpeg")
    if shutil_which:
        return os.path.dirname(shutil_which)
    for d in candidates:
        if os.path.isfile(os.path.join(d, "ffmpeg")) and os.path.isfile(os.path.join(d, "ffprobe")):
            return d
    return None


def _pick(results: list, title: str) -> dict | None:
    """Best result for a query that still carried the artist.

    Unchanged ranking: prefer songs whose title contains the requested one
    (robust to YT's "(Remastered 2015)" suffixes), then any song, then
    song-or-video — official artist channels often list tracks as videos.
    """
    songs = [r for r in results if r.get("resultType") == "song"]
    matches = [s for s in songs if query_variants.title_matches(title, s.get("title"))]
    pool = matches or songs or [
        r for r in results if r.get("resultType") in ("song", "video")
    ]
    return pool[0] if pool else None


def _pick_title_only(results: list, title: str, artist: str) -> dict | None:
    """Best result for the title-only rung, which must verify, not accept.

    Dropping the artist from the query means the top hit is frequently a
    different act's song of the same name, so this rung requires BOTH a
    title match AND artist evidence. "52 Street" and "52nd Street" share
    "street" and match; an unrelated act sharing only a stopword does not.
    Without that, the last resort would quietly play the wrong song, which
    is worse than reporting NO_MATCH.
    """
    for r in results:
        if r.get("resultType") not in ("song", "video"):
            continue
        if not query_variants.title_matches(title, r.get("title")):
            continue
        found = ", ".join(
            a.get("name", "") for a in (r.get("artists") or []) if isinstance(a, dict)
        )
        if query_variants.artists_plausibly_match(artist, found):
            return r
    return None


def best_match(artist: str, title: str) -> tuple[str, str]:
    """Return (youtube_id, matched_title) or raise RuntimeError('NO_MATCH').

    Tries progressively simpler queries rather than giving up after one.
    NTS artist fields are scraped free text, and a trailing "_" or a
    colon-joined second artist is enough to zero the result set while the
    track is sitting right there in the catalogue.

    The full query runs first and unchanged, so anything that resolves today
    resolves identically and never reaches the fallbacks.
    """
    client = YTMusic()
    variants = query_variants.build_query_variants(artist, title)
    title_only = variants[-1] if len(variants) > 1 else None

    for query in variants:
        results = client.search(query) or []
        if not results:
            continue
        if query == title_only:
            top = _pick_title_only(results, title, artist)
        else:
            top = _pick(results, title)
        if top and top.get("videoId"):
            return top["videoId"], top.get("title") or title

    raise RuntimeError("NO_MATCH")


def _download_url(url: str, output: str) -> dict:
    """Download audio at `url` to `output` (m4a). Returns the yt-dlp info dict.

    yt-dlp's FFmpegExtractAudio post-processor appends its own extension.
    If the caller passes `/foo/<uuid>.m4a`, naively setting `outtmpl` to
    that path yields `/foo/<uuid>.m4a.m4a`. Strip the final `.m4a` from
    the template, let the post-processor put it back, then rename to the
    exact path the caller requested.
    """
    # Strip trailing extension so yt-dlp's post-processor writes <stem>.m4a.
    stem, ext = os.path.splitext(output)
    tmpl_base = stem if ext.lower() == ".m4a" else output

    opts = {
        "format": "bestaudio/best",
        "outtmpl": tmpl_base,
        "quiet": True,
        "no_warnings": True,
        # Belt-and-suspenders with `quiet`: some yt-dlp versions still emit
        # progress-bar carriage-return lines to stdout even under `quiet`,
        # which corrupts our JSON-on-stdout contract with Swift.
        "noprogress": True,
        "postprocessors": [
            {"key": "FFmpegExtractAudio", "preferredcodec": "m4a"},
        ],
        "retries": 3,
        "fragment_retries": 3,
        # yt-dlp picks a mildly annoying default "web" client that 403s a
        # lot on music.youtube.com; the android client is more reliable.
        # Bandcamp and other extractors ignore this option (YouTube-only).
        "extractor_args": {"youtube": {"player_client": ["android", "web"]}},
    }
    ffmpeg_dir = _locate_ffmpeg()
    if ffmpeg_dir:
        opts["ffmpeg_location"] = ffmpeg_dir
    # Hard-redirect stdout around yt-dlp so anything else that slips past
    # `quiet`/`noprogress` (e.g. ffmpeg post-processor chatter) can't
    # corrupt the resolver's stdout contract. Captured text is dropped —
    # real errors still surface via stderr and raised exceptions.
    silenced = io.StringIO()
    info: dict = {}
    with contextlib.redirect_stdout(silenced):
        with YoutubeDL(opts) as ydl:
            # extract_info(download=True) returns the populated info dict —
            # ydl.download() throws that away and we want the extractor id
            # + resolved title for the caller's synthetic-id / matched-title.
            info = ydl.extract_info(url, download=True) or {}

    produced = tmpl_base + ".m4a"
    if produced != output and os.path.exists(produced):
        # Guarantee the exact caller-requested path.
        os.replace(produced, output)

    if not os.path.exists(output):
        raise RuntimeError(f"expected output file not found: {output}")

    return info


def _describe(info: dict) -> dict:
    """Pull the display metadata Swift wants out of a yt-dlp info dict.

    Deliberately read-only: we do NOT ask yt-dlp to embed metadata or
    thumbnails into the file. Those post-processors shell out to ffmpeg
    after the download and can fail on their own, which would turn a
    perfectly good track into a failed resolve — and a failed resolve on
    an always-on radio is dead air. Reporting what the extractor already
    knows costs nothing and cannot break the download.

    Every key is optional: extractors disagree about what they populate,
    and the Swift side decodes all of these as optionals.

    ## Playlists

    A Bandcamp ALBUM url — which is most of what the Bandcamp station
    resolves — produces `_type == "playlist"`. The top level of that dict
    carries no album, duration or thumbnail at all; they live on each
    entry. Reading only the top level is why the first deploy of this
    reported nothing for every Bandcamp track:

        TOPLEVEL: {'album': None, 'duration': None, 'thumbnail': None,
                   'title': "Don't Know How Fast I'm Moving…"}
        ENTRY0:   {'album': "Don't Know How Fast I'm Moving…",
                   'duration': 344.955,
                   'thumbnail': 'https://f4.bcbits.com/img/a3028845176_5.jpg'}

    So fall through to the first entry. Two deliberate exceptions:

    - The album name prefers the playlist's own `title`, which is right for
      every entry rather than just the one we happened to look at.
    - `duration` is NOT taken from a playlist entry. All entries download
      to the same output path, so the file on disk is one specific track
      and we cannot be sure which; a per-entry duration would be a
      confident guess. Swift measures the file it actually opens instead.
    """
    out: dict = {}
    entries = info.get("entries") or []
    is_playlist = bool(entries) and isinstance(entries[0], dict)
    entry = entries[0] if is_playlist else {}

    album = info.get("album")
    if is_playlist and not album:
        # Playlist title == release name, and true for every entry.
        album = info.get("title") or entry.get("album")
    if isinstance(album, str) and album.strip():
        out["album"] = album.strip()

    if not is_playlist:
        duration = info.get("duration")
        if isinstance(duration, (int, float)) and duration > 0:
            out["duration"] = float(duration)

    thumb = info.get("thumbnail") or (entry.get("thumbnail") if is_playlist else None)
    if not thumb:
        # Some extractors only fill the `thumbnails` list. Prefer the last
        # entry — yt-dlp sorts it worst-to-best.
        thumbs = info.get("thumbnails") or entry.get("thumbnails") or []
        if isinstance(thumbs, list) and thumbs:
            last = thumbs[-1]
            thumb = last.get("url") if isinstance(last, dict) else None
    if isinstance(thumb, str) and thumb.startswith("http"):
        out["thumbnail"] = thumb
    return out


def download(yt_id: str, output: str) -> dict:
    """Download audio for YouTube ID to output path (m4a).

    Returns the display metadata dict (see `_describe`).
    """
    return _describe(_download_url(f"https://music.youtube.com/watch?v={yt_id}", output))


def download_direct(url: str, output: str) -> tuple[str, str, dict]:
    """Download audio from a pre-resolved source URL.

    Returns `(synthetic_id, matched_title, metadata)` — the synthetic id is
    `"<extractor>:<extractor-track-id>"` (e.g. `"bandcamp:1234567890"`)
    so downstream dedup/annotation has a stable handle even though
    there's no YouTube catalog entry. `metadata` is the display dict from
    `_describe`.
    """
    info = _download_url(url, output)
    extractor = (info.get("extractor_key") or info.get("extractor") or "source").lower()
    track_id = info.get("id") or info.get("display_id") or url
    matched = info.get("track") or info.get("title") or ""
    return f"{extractor}:{track_id}", matched, _describe(info)


def main() -> int:
    ap = argparse.ArgumentParser()
    # --artist/--title are required for search mode and useful as fallback
    # metadata in direct-URL mode (the wrapper echoes them back if yt-dlp's
    # info dict doesn't carry a clean track title).
    ap.add_argument("--artist", required=True)
    ap.add_argument("--title", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument(
        "--source-url",
        default=None,
        help=(
            "Pre-resolved audio URL (e.g. Bandcamp release page). When set, "
            "skip the YouTube Music search and hand the URL to yt-dlp."
        ),
    )
    args = ap.parse_args()

    if args.source_url:
        # Direct-URL path — no YT-Music search, yt-dlp handles the extractor.
        try:
            synthetic_id, matched, meta = download_direct(args.source_url, args.output)
        except Exception as e:  # noqa: BLE001
            print(f"download_failed: {e}", file=sys.stderr)
            return 3
        # Fall back to the caller-supplied title if the extractor didn't
        # surface a usable one.
        if not matched:
            matched = args.title
        print(
            json.dumps(
                {"youtube_id": synthetic_id, "matched_title": matched, **meta}
            ),
            flush=True,
        )
        return 0

    try:
        yt_id, matched = best_match(args.artist, args.title)
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001 - surface full reason on stderr
        print(f"search_failed: {e}", file=sys.stderr)
        return 2

    try:
        meta = download(yt_id, args.output)
    except Exception as e:  # noqa: BLE001
        print(f"download_failed: {e}", file=sys.stderr)
        return 3

    print(
        json.dumps({"youtube_id": yt_id, "matched_title": matched, **meta}),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
