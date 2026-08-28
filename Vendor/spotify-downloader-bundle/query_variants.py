"""Progressive YouTube Music query construction.

The resolver used to build exactly one query, ``f"{title} {artist}"``, and
raise NO_MATCH when it came back empty. NTS tracklists are scraped from
free-text listings, so the artist field arrives with whatever the show host
typed, and a single character of it is enough to zero the result set:

    "DUMB HUMMER FACTA _"                        -> 0 songs
    "DUMB HUMMER FACTA"                          -> 1 song   "Dumb Hummer"

    "Prati Bagnati Del Monte Analogo
       Raul Lovisoni: Francesco Messina"         -> 0 songs
    "Prati Bagnati Del Monte Analogo
       Raul Lovisoni"                            -> 1 song

    "Look Into My Eyes 52 Street"                -> 0 songs
        (genuine naming mismatch: the band is "52nd Street", so no amount
         of cleaning the artist helps — only dropping it does)

So: try progressively simpler queries instead of giving up after one.

**The full query is always tried first, unchanged.** That matters more than
any cleaning rule below, because it means sanitisation can only ever be
consulted for a query that has *already returned nothing*. A name that works
today keeps working and never reaches these rules at all.

Deliberately NOT split on, at the conservative rungs:

    "&"   Earth, Wind & Fire / Simon & Garfunkel / Kool & The Gang
    "/"   AC/DC

Those are single artists whose names contain the separator, and splitting on
them would turn a correct name into a wrong one. They are still tried, but
only at the last rung before title-only, after the safer readings have
failed — and every rung's result is verified, so a bad split tends to return
nothing rather than the wrong song.

Pure stdlib on purpose: `resolve_track.py` imports ytmusicapi and yt_dlp at
module level, which no test machine needs to have installed to check this.
"""
from __future__ import annotations

import re

# Featuring markers. Unambiguous — these never appear inside a single
# artist's name as a word.
_FEAT = re.compile(
    r"\s+(?:feat\.?|ft\.?|featuring|w/|with)\s+.*$",
    re.IGNORECASE,
)

# Collaboration marker: a lone "x" between spaces ("Artist A x Artist B").
# Spaced on both sides so "Charli XCX" and "Madlib" are untouched.
_X_JOIN = re.compile(r"\s+x\s+.*$", re.IGNORECASE)

# Junk the scrape leaves behind: a standalone underscore, or runs of
# separator punctuation stranded at either end of the field.
_STANDALONE_UNDERSCORE = re.compile(r"(?:(?<=\s)|^)_+(?=\s|$)")
_EDGE_JUNK = re.compile(r"^[\s\-–—_,:;/&+|.]+|[\s\-–—_,:;/&+|.]+$")

_WS = re.compile(r"\s+")

# Tokens too common to count as evidence that two artist names refer to the
# same act.
_STOPWORDS = frozenset(
    {"the", "and", "a", "an", "of", "his", "her", "their", "band", "orchestra"}
)


def collapse_whitespace(value: str) -> str:
    return _WS.sub(" ", value).strip()


def strip_junk(artist: str) -> str:
    """Remove scrape debris without touching the name itself.

    Handles the `FACTA _` case. Never returns empty: a name made entirely of
    punctuation ("!!!") is left as it was, because for that band the
    punctuation *is* the name.
    """
    cleaned = _STANDALONE_UNDERSCORE.sub(" ", artist)
    cleaned = _EDGE_JUNK.sub("", cleaned)
    cleaned = collapse_whitespace(cleaned)
    return cleaned or collapse_whitespace(artist)


def primary_artist(artist: str, aggressive: bool = False) -> str:
    """The first artist in a multi-artist field.

    Conservative by default: featuring markers, a spaced "x", and ":" — the
    last being the observed failure, and rare enough inside a real name to be
    safe. `aggressive` additionally splits on "," "&" "/", which do occur
    inside legitimate names, and so is only used at a late rung.
    """
    value = _FEAT.sub("", artist)
    value = _X_JOIN.sub("", value)
    value = value.split(":", 1)[0]
    if aggressive:
        for sep in (",", "&", "/", " + "):
            value = value.split(sep, 1)[0]
    value = strip_junk(value)
    return value or strip_junk(artist)


def build_query_variants(artist: str, title: str) -> list[str]:
    """Ordered, de-duplicated queries to try, widest match first.

    Every entry is a real query; identical rungs collapse, so a clean artist
    name yields a single query and costs exactly what it does today.
    The title-only rung is last and is verified more strictly by the caller.
    """
    title = collapse_whitespace(title)
    artist = collapse_whitespace(artist)

    candidates = [
        f"{title} {artist}",                                    # unchanged
        f"{title} {strip_junk(artist)}",                        # scrape debris
        f"{title} {primary_artist(artist)}",                    # safe separators
        f"{title} {primary_artist(artist, aggressive=True)}",   # risky separators
        title,                                                  # last resort
    ]

    out: list[str] = []
    for c in candidates:
        c = collapse_whitespace(c)
        if c and c not in out:
            out.append(c)
    return out


# --- Verification -----------------------------------------------------------

_TOKEN = re.compile(r"[a-z0-9]+")


def _tokens(value: str) -> set[str]:
    return {
        t for t in _TOKEN.findall((value or "").lower())
        if len(t) >= 2 and t not in _STOPWORDS
    }


def artists_plausibly_match(requested: str, found: str) -> bool:
    """Do two artist strings refer to the same act?

    Token overlap rather than equality, because the whole reason the
    title-only rung exists is that the scraped name is not quite the
    catalogue's: "52 Street" vs "52nd Street" share "street" and should
    match, while an unrelated act sharing only a stopword should not.
    """
    a, b = _tokens(requested), _tokens(found)
    if not a or not b:
        return False
    return bool(a & b)


def title_matches(requested: str, found: str) -> bool:
    """Is `found` the requested title, allowing catalogue suffixes?

    YouTube Music appends things like "(Remastered 2015)" and
    "(Original Mix)", so containment rather than equality.
    """
    r = collapse_whitespace((requested or "").lower())
    f = collapse_whitespace((found or "").lower())
    return bool(r) and r in f
