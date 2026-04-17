#!/usr/bin/env python3
"""Ratbat download wrapper.

Invoked by Ratbat's Swift DownloadService:
    download.py --url SPOTIFY_URL --output DEST_DIR

Calls spotify-downloader.core.main() for the heavy lifting.
Progress appears on stdout as the `[MATCHING]` / `[FOUND]` /
`[download]` lines that core.py + yt-dlp already emit — Swift
parses those directly.
"""
import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from core import main as sd_main  # noqa: E402


def run(url: str, output_dir: str) -> None:
    os.makedirs(output_dir, exist_ok=True)
    sd_main(
        playlist_id=url,
        output_dir=output_dir,
        audio_format="m4a",
        title_first=False,
        concurrent_limit=3,
        download_archive=".archive",
    )


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    run(args.url, args.output)
