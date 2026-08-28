"""Tests for the resolver's progressive query fallback.

Stdlib only, so this runs anywhere without ytmusicapi or yt_dlp installed.

    python3 -m unittest discover -s Vendor/spotify-downloader-bundle -v

The cases below are split into two halves that pull against each other:
strings that MUST be simplified (real NTS scrapes that returned 0 results)
and names that MUST NOT be mangled. The second half is the one that stops
this becoming a regex that quietly breaks AC/DC.
"""
import unittest

from query_variants import (
    artists_plausibly_match,
    build_query_variants,
    primary_artist,
    strip_junk,
    title_matches,
)


class StripJunk(unittest.TestCase):
    """Scrape debris, measured against real NTS artist fields."""

    def test_real_failures(self):
        # "DUMB HUMMER FACTA _" -> 0 results; without the "_" -> 1 result.
        self.assertEqual(strip_junk("FACTA _"), "FACTA")
        self.assertEqual(strip_junk("FACTA  _  "), "FACTA")
        self.assertEqual(strip_junk("_ FACTA"), "FACTA")

    def test_edge_separators(self):
        for raw, want in [
            ("Aphex Twin -", "Aphex Twin"),
            ("- Aphex Twin", "Aphex Twin"),
            ("Aphex Twin,", "Aphex Twin"),
            ("Aphex Twin:", "Aphex Twin"),
            ("Aphex Twin /", "Aphex Twin"),
            ("Aphex   Twin", "Aphex Twin"),
        ]:
            with self.subTest(raw=raw):
                self.assertEqual(strip_junk(raw), want)

    def test_does_not_mangle_real_names(self):
        for name in [
            "AC/DC",
            "Earth, Wind & Fire",
            "Simon & Garfunkel",
            "Kool & The Gang",
            "Florence + the Machine",
            "Tyler, The Creator",
            "Godspeed You! Black Emperor",
            "Sun Ra & His Arkestra",
            "65daysofstatic",
            "A Tribe Called Quest",
            "Nine Inch Nails",
            "Sunn O)))",
        ]:
            with self.subTest(name=name):
                self.assertEqual(strip_junk(name), name)

    def test_a_name_that_is_only_punctuation_survives(self):
        # For this band the punctuation IS the name.
        self.assertEqual(strip_junk("!!!"), "!!!")
        self.assertNotEqual(strip_junk("!!!"), "")

    def test_a_name_with_content_never_becomes_empty(self):
        # Fields that are *entirely* junk have nothing to preserve and may
        # come back empty; the caller drops such a query. What must never
        # happen is a name with real content being stripped to nothing.
        for raw in ["_", "---", ",,,", ":"]:
            with self.subTest(raw=raw):
                self.assertNotEqual(strip_junk(raw), "", "punctuation-only name kept")
        self.assertEqual(strip_junk("   "), "", "a blank field is genuinely blank")


class PrimaryArtist(unittest.TestCase):
    def test_real_failure_colon_joined(self):
        # "... Raul Lovisoni: Francesco Messina" -> 0 results;
        # "... Raul Lovisoni" -> 1 result.
        self.assertEqual(
            primary_artist("Raul Lovisoni: Francesco Messina"), "Raul Lovisoni"
        )

    def test_featuring_markers(self):
        for raw in [
            "Burial feat. Four Tet",
            "Burial feat Four Tet",
            "Burial ft. Four Tet",
            "Burial ft Four Tet",
            "Burial featuring Four Tet",
            "Burial with Four Tet",
            "Burial w/ Four Tet",
        ]:
            with self.subTest(raw=raw):
                self.assertEqual(primary_artist(raw), "Burial")

    def test_spaced_x_collaboration(self):
        self.assertEqual(primary_artist("Skee Mask x Zenker Brothers"), "Skee Mask")

    def test_conservative_pass_keeps_ampersand_and_slash_names(self):
        # The whole point: these are single artists, not collaborations.
        for name in ["AC/DC", "Earth, Wind & Fire", "Simon & Garfunkel",
                     "Kool & The Gang", "Tyler, The Creator"]:
            with self.subTest(name=name):
                self.assertEqual(primary_artist(name), name)

    def test_x_inside_a_word_is_not_a_separator(self):
        for name in ["Charli XCX", "Madlib", "Xhin", "Max Cooper"]:
            with self.subTest(name=name):
                self.assertEqual(primary_artist(name), name)

    def test_aggressive_pass_splits_the_risky_separators(self):
        self.assertEqual(
            primary_artist("Emmanuel Jal, Henrik Schwarz", aggressive=True),
            "Emmanuel Jal",
        )
        self.assertEqual(primary_artist("Mall Grab & DJ Boring", aggressive=True), "Mall Grab")

    def test_never_returns_empty(self):
        self.assertNotEqual(primary_artist(": Francesco Messina"), "")
        self.assertNotEqual(primary_artist("feat. Someone"), "")


class QueryVariants(unittest.TestCase):
    def test_full_query_is_always_first_and_unchanged(self):
        v = build_query_variants("Aphex Twin", "Xtal")
        self.assertEqual(v[0], "Xtal Aphex Twin")

    def test_a_clean_name_costs_exactly_one_extra_rung(self):
        # Nothing to simplify, so only the full query and the title-only
        # last resort remain after de-duplication.
        self.assertEqual(build_query_variants("Aphex Twin", "Xtal"),
                         ["Xtal Aphex Twin", "Xtal"])

    def test_facta_underscore_produces_the_working_query(self):
        v = build_query_variants("FACTA _", "DUMB HUMMER")
        self.assertEqual(v[0], "DUMB HUMMER FACTA _")
        self.assertIn("DUMB HUMMER FACTA", v)          # the one that returns a hit
        self.assertLess(v.index("DUMB HUMMER FACTA"), v.index("DUMB HUMMER"))

    def test_colon_joined_artist_produces_the_working_query(self):
        v = build_query_variants(
            "Raul Lovisoni: Francesco Messina", "Prati Bagnati Del Monte Analogo"
        )
        self.assertEqual(v[0],
                         "Prati Bagnati Del Monte Analogo Raul Lovisoni: Francesco Messina")
        self.assertIn("Prati Bagnati Del Monte Analogo Raul Lovisoni", v)

    def test_title_only_is_the_last_resort(self):
        v = build_query_variants("52 Street", "Look Into My Eyes")
        self.assertEqual(v[-1], "Look Into My Eyes")

    def test_no_duplicate_queries(self):
        v = build_query_variants("FACTA _", "DUMB HUMMER")
        self.assertEqual(len(v), len(set(v)))

    def test_every_variant_is_non_empty(self):
        for artist in ["_", "!!!", "AC/DC", "Raul Lovisoni: Francesco Messina", ""]:
            with self.subTest(artist=artist):
                for q in build_query_variants(artist, "Some Title"):
                    self.assertTrue(q.strip())


class Verification(unittest.TestCase):
    """The title-only rung must verify, not accept whatever is on top."""

    def test_scraped_name_matches_catalogue_spelling(self):
        # The real case: NTS said "52 Street", the catalogue says "52nd Street".
        self.assertTrue(artists_plausibly_match("52 Street", "52nd Street"))

    def test_unrelated_artist_is_rejected(self):
        self.assertFalse(artists_plausibly_match("52 Street", "Taylor Swift"))
        self.assertFalse(artists_plausibly_match("FACTA", "Aphex Twin"))

    def test_a_shared_stopword_is_not_evidence(self):
        self.assertFalse(artists_plausibly_match("The Cure", "The Beatles"))
        self.assertFalse(artists_plausibly_match("A Band", "An Orchestra"))

    def test_partial_and_reordered_names_match(self):
        self.assertTrue(artists_plausibly_match("Four Tet", "Four Tet & Burial"))
        self.assertTrue(artists_plausibly_match("Raul Lovisoni: Francesco Messina",
                                                "Raul Lovisoni"))

    def test_empty_side_never_matches(self):
        self.assertFalse(artists_plausibly_match("", "Aphex Twin"))
        self.assertFalse(artists_plausibly_match("Aphex Twin", ""))

    def test_title_matching_tolerates_catalogue_suffixes(self):
        self.assertTrue(title_matches("Dumb Hummer", "Dumb Hummer"))
        self.assertTrue(title_matches("Dumb Hummer", "Dumb Hummer (Original Mix)"))
        self.assertTrue(title_matches("Xtal", "Xtal (Remastered 2015)"))

    def test_title_matching_rejects_a_different_song(self):
        self.assertFalse(title_matches("Dumb Hummer", "Windowlicker"))
        self.assertFalse(title_matches("Look Into My Eyes", "Look"))


if __name__ == "__main__":
    unittest.main()
