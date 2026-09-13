import pytest

from common.normalize import (
    MIN_BLOCKING_FP_LENGTH,
    NORMALIZER_VERSION,
    fingerprint,
    name_fingerprint,
    title_fingerprints,
)


def test_normalizer_version_is_an_int():
    assert isinstance(NORMALIZER_VERSION, int)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("The Great Gatsby", "the great gatsby"),
        ("Les Misérables", "les miserables"),
        ("L'Étranger", "l etranger"),
        ("naïve café", "naive cafe"),
        ("O'Brien—Vol. II", "o brien vol ii"),
        ("The\xa0Hobbit", "the hobbit"),  # non-breaking space
        ("  spaced   out  ", "spaced out"),
        ("!!!", ""),
        (None, ""),
        ("", ""),
    ],
)
def test_fingerprint_normalizes(raw, expected):
    assert fingerprint(raw) == expected


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("99 Франков", "99"),  # Cyrillic is erased; only the digits survive
        ("日本語のタイトル", ""),  # CJK is erased entirely
        ("Þórr", "orr"),
        ("Æsop's Fables", "sop s fables"),
        ("Straße", "stra e"),
    ],
)
def test_fingerprint_is_lossy_on_non_latin_scripts(raw, expected):
    # This is a recorded property, not a bug: the spec's recall numbers were
    # measured with this normalization. A book whose title fingerprints to ""
    # or to digits alone is reachable ONLY by identifier or by an existing OL key.
    assert fingerprint(raw) == expected


def test_min_blocking_length_matches_the_measured_degenerate_cutoff():
    # 3,360 of 126,330 books (2.7%) have a title fingerprint shorter than this.
    assert MIN_BLOCKING_FP_LENGTH == 4


def test_subtitle_variant_cuts_at_first_colon_semicolon_or_paren():
    assert title_fingerprints("Ulysses: A Novel").nosub == "ulysses"
    assert title_fingerprints("Dune; or, The Spice").nosub == "dune"
    assert title_fingerprints("Hamlet (Arden Edition)").nosub == "hamlet"


def test_subtitle_variant_falls_back_when_the_cut_is_degenerate():
    # "It: A Novel" would cut to "it" (2 chars) and become an unusable key.
    fps = title_fingerprints("It: A Novel")
    assert fps.full == "it a novel"
    assert fps.nosub == "it a novel"


def test_article_variant_strips_only_leading_english_articles():
    assert title_fingerprints("The Great Gatsby").noart == "great gatsby"
    assert title_fingerprints("A Passage to India").noart == "passage to india"
    assert title_fingerprints("An American Tragedy").noart == "american tragedy"
    # Not an article at the front, so nothing is stripped.
    assert title_fingerprints("Theft").noart == "theft"
    # Non-English articles are deliberately NOT stripped: "La Bamba" and
    # "Le Rouge" would collapse into unrelated blocking keys, and our titles
    # are overwhelmingly English. Revisit only with a measurement.
    assert title_fingerprints("La Peste").noart == "la peste"


def test_article_variant_falls_back_when_the_strip_is_degenerate():
    fps = title_fingerprints("The Sea")
    assert fps.full == "the sea"
    assert fps.noart == "the sea"


def test_all_three_variants_are_present_for_a_plain_title():
    fps = title_fingerprints("The Hobbit")
    assert (fps.full, fps.nosub, fps.noart) == ("the hobbit", "the hobbit", "hobbit")


def test_name_fingerprint_uses_the_same_algorithm():
    assert name_fingerprint("Gabriel García Márquez") == "gabriel garcia marquez"
    assert name_fingerprint(None) == ""
