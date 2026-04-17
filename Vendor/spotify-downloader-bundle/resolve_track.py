#!/usr/bin/env python3
"""Ratbat track resolver.

Given (artist, title), find the best YouTube Music match and download
audio to the given output path. Prints JSON result on stdout.

Usage:
    resolve_track.py --artist ARTIST --title TITLE --output PATH

Success (stdout):
    {"youtube_id": "dQw4w9WgXcQ", "matched_title": "..."}

Failure (stderr, non-zero exit):
    Human-readable error; includes "NO_MATCH" if nothing found.

Exit codes:
    0 = success
    1 = no YouTube Music match
    2 = search failure (network / API error)
    3 = download failure
"""
import argparse
import json
import os
import sys

from ytmusicapi import YTMusic
from yt_dlp import YoutubeDL


def best_match(artist: str, title: str) -> tuple[str, str]:
    """Return (youtube_id, matched_title) or raise RuntimeError('NO_MATCH')."""
    client = YTMusic()
    query = f"{title} {artist}".strip()
    results = client.search(query) or []

    title_lc = title.lower().strip()

    # 1. Prefer songs whose title contains the requested title (robust to
    #    YT's "(Remastered 2015)" suffixes).
    songs = [r for r in results if r.get("resultType") == "song"]
    title_matches = [s for s in songs if title_lc in (s.get("title") or "").lower()]

    # 2. Fall back to any song result.
    # 3. Then any song-or-video result (official artist channels often list
    #    tracks as videos rather than songs).
    pool = title_matches or songs or [
        r for r in results if r.get("resultType") in ("song", "video")
    ]

    if not pool:
        raise RuntimeError("NO_MATCH")

    top = pool[0]
    vid = top.get("videoId")
    if not vid:
        raise RuntimeError("NO_MATCH")
    return vid, top.get("title") or title


def download(yt_id: str, output: str) -> None:
    """Download audio for YouTube ID to output path (m4a).

    yt-dlp's FFmpegExtractAudio post-processor appends its own extension.
    If the caller passes `/foo/<uuid>.m4a`, naively setting `outtmpl` to
    that path yields `/foo/<uuid>.m4a.m4a`. Strip the final `.m4a` from
    the template, let the post-processor put it back, then rename to the
    exact path the caller requested.
    """
    url = f"https://music.youtube.com/watch?v={yt_id}"

    # Strip trailing extension so yt-dlp's post-processor writes <stem>.m4a.
    stem, ext = os.path.splitext(output)
    tmpl_base = stem if ext.lower() == ".m4a" else output

    opts = {
        "format": "bestaudio/best",
        "outtmpl": tmpl_base,
        "quiet": True,
        "no_warnings": True,
        "postprocessors": [
            {"key": "FFmpegExtractAudio", "preferredcodec": "m4a"},
        ],
        "retries": 3,
        "fragment_retries": 3,
        # yt-dlp picks a mildly annoying default "web" client that 403s a
        # lot on music.youtube.com; the android client is more reliable.
        "extractor_args": {"youtube": {"player_client": ["android", "web"]}},
    }
    with YoutubeDL(opts) as ydl:
        ydl.download([url])

    produced = tmpl_base + ".m4a"
    if produced != output and os.path.exists(produced):
        # Guarantee the exact caller-requested path.
        os.replace(produced, output)

    if not os.path.exists(output):
        raise RuntimeError(f"expected output file not found: {output}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--artist", required=True)
    ap.add_argument("--title", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    try:
        yt_id, matched = best_match(args.artist, args.title)
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001 - surface full reason on stderr
        print(f"search_failed: {e}", file=sys.stderr)
        return 2

    try:
        download(yt_id, args.output)
    except Exception as e:  # noqa: BLE001
        print(f"download_failed: {e}", file=sys.stderr)
        return 3

    print(json.dumps({"youtube_id": yt_id, "matched_title": matched}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
