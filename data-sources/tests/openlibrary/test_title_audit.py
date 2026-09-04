"""Title text that defeats the matcher.

`title_fp_nosub` strips the *subtitle field*. It cannot help when the subtitle,
a volume number or a date range was concatenated into the title itself, which
is what the old importer did -- and that is the whole reason two real books in
the `no_candidates` stratum produced no candidate at all.

Every case below is a real exported title, so a change that reclassifies one is
a change to a number in `docs/data-quality/`.
"""

from __future__ import annotations

import pytest

from common.normalize import fingerprint
from openlibrary.audit.titles import (
    classify_title_collision,
    strip_matching_noise,
    title_repeats_subtitle,
)

# Book #143219. OL holds this as `Andrew Jackson and the Course of the American
# Empire` (OL273027W); we hold the same string with the date range and the
# volume number glued on. That single difference is why all four blocking rules
# produced nothing.
REMINI = "Andrew Jackson And The Course Of The American Empire, 1767 1821 Volume I"


def test_the_remini_title_matches_open_library_once_the_noise_is_gone():
    assert fingerprint(strip_matching_noise(REMINI)) == fingerprint(
        "Andrew Jackson and the Course of the American Empire"
    )


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        # Book #43599: a German subtitle carrying the years the book covers.
        (
            "Mit Gott Durch Dick Und Dünn Weltreisende Mit Guter Nachricht 1945 1975",
            "Mit Gott Durch Dick Und Dünn Weltreisende Mit Guter Nachricht",
        ),
        ("Collected Poems, 1954–2004", "Collected Poems"),
        ("Selected Writings, 1950 1990", "Selected Writings"),
        ("The Sandman Volume 3", "The Sandman"),
        ("Berserk Vol. 12", "Berserk"),
        ("Lone Wolf And Cub Volume XII", "Lone Wolf And Cub"),
    ],
)
def test_trailing_volume_and_date_ranges_come_off(raw, expected):
    assert strip_matching_noise(raw) == expected


@pytest.mark.parametrize(
    "raw",
    [
        # A lone year is not a range. `1984` is the whole title of a real book,
        # and stripping single years would erase it.
        "1984",
        "1984 And After",
        "The War Book Of The German General Staff 1914",
        # `Volume` inside a title, not trailing.
        "The Volume Of The Book",
        "Dune",
    ],
)
def test_a_title_without_trailing_noise_is_untouched(raw):
    assert strip_matching_noise(raw) == raw


def test_a_title_that_is_nothing_but_noise_is_left_alone():
    """Stripping to an empty string would turn one unmatched book into a book
    that blocks against every work with an empty fingerprint."""
    assert strip_matching_noise("Volume II") == "Volume II"
    assert strip_matching_noise("1767-1821") == "1767-1821"


@pytest.mark.parametrize(
    ("title", "subtitle", "expected"),
    [
        ("Why Survive? Being Old in America", "Being Old in America", True),
        ("The Water-Babies, A Fairy Tale for a Land Baby", "A Fairy Tale for a Land Baby", True),
        ("I, Tituba, Black Witch of Salem", "black witch of salem", True),
        ("The Golden Apple", "A Novel", False),
        ("The Golden Apple", None, False),
        ("The Golden Apple", "", False),
        # Too short to be evidence of anything.
        ("A Book of Ice", "Ice", False),
    ],
)
def test_a_title_that_swallowed_its_own_subtitle_is_detected(title, subtitle, expected):
    assert title_repeats_subtitle(title, subtitle) is expected


def test_a_backwards_year_pair_is_part_of_the_title_not_noise():
    """Book #13733, Bellamy's `Looking Backward, 2000-1887` -- the only
    backwards pair in 157,805 exported titles, and the years run that way
    because the novel looks back from 2000 to 1887.

    Stripping it would be a net loss, not a wash: `looking backward 2000 1887`
    is on 37 OL works and blocks today, while `looking backward` is on 57 --
    over MAX_TITLE_FP_FREQ, so the title_fp rule would suppress it and the book
    would go from 37 candidates to none."""
    assert strip_matching_noise("Looking Backward, 2000 1887") == "Looking Backward, 2000 1887"


# Two of our Book rows can share an (author, title) for opposite reasons: the
# importer truncated a series title so different books collapsed onto one
# string, or the same book was imported twice. Those need opposite repairs --
# split versus merge -- and guessing from the title alone gets it wrong. Open
# Library arbitrates: resolve each row's identifiers to work keys and look at
# whether the rows landed on the same work.
#
# Every group below is a real one from the 146 in the export.


def test_rows_landing_on_a_common_work_are_duplicate_rows():
    """`The Road` x3 by Cormac McCarthy. Two rows resolve to OL40873W alone and
    the third resolves to it among others -- one book, three times."""
    assert (
        classify_title_collision(
            [
                {"OL15574537W", "OL19840020W", "OL40873W"},
                {"OL40873W"},
                {"OL40873W"},
            ]
        )
        == "duplicate_rows"
    )


def test_rows_landing_on_disjoint_works_are_distinct_books():
    """`X Men` x5 by Scott Lobdell -- five different comics collapsed onto the
    series name. No two rows share a work."""
    assert (
        classify_title_collision(
            [
                {"OL19297075W", "OL2888297W"},
                {"OL14976827W"},
                {"OL25003202W"},
                {"OL2257225W"},
                {"OL17536546W", "OL20458326W", "OL38036212W"},
            ]
        )
        == "distinct_books"
    )


def test_a_group_open_library_cannot_speak_for_is_unresolved():
    """`Animal Farm` x3 by Orwell: one row resolves, two carry no identifier OL
    knows. One opinion is not a comparison, and calling it either way would
    invent a finding."""
    assert classify_title_collision([{"OL1168007W", "OL33244798W"}, set(), set()]) == "unresolved"
    assert classify_title_collision([set(), set()]) == "unresolved"


def test_rows_that_cluster_into_more_than_one_work_are_mixed():
    """`JoJo's Bizarre Adventure` x28 by (the wrong) Araki: some rows land on
    OL24236464W, others on OL20744477W. Both truncation AND duplication in one
    group, so neither repair is safe to apply wholesale."""
    assert (
        classify_title_collision(
            [
                {"OL24236464W"},
                {"OL24236464W"},
                {"OL24236464W"},
                {"OL20744477W"},
                {"OL20744477W"},
                {"OL20744477W"},
            ]
        )
        == "mixed"
    )
