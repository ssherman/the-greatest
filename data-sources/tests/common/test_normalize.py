"""Tests for `identifier_pairs`, the shared canonicalizer that the matcher's
blocking rule 1 and the evaluation pool's `_identifier_pairs` delegate both
call -- see the docstring on `common.normalize.identifier_pairs` for why
canonicalization has to happen before the exact-equality join.
"""

from __future__ import annotations

from common.normalize import identifier_pairs, query_title_variants


def test_a_hyphenated_isbn10_contributes_both_forms():
    assert identifier_pairs(isbn10=["0-306-40615-2"]) == [
        ("isbn10", "0306406152"),
        ("isbn13", "9780306406157"),
    ]


def test_an_asin_that_is_an_isbn10_contributes_asin_and_both_isbn_forms():
    assert identifier_pairs(asin=["0306406152"]) == [
        ("asin", "0306406152"),
        ("isbn10", "0306406152"),
        ("isbn13", "9780306406157"),
    ]


def test_a_non_isbn_asin_contributes_asin_only():
    assert identifier_pairs(asin=["B000FC0SIS"]) == [("asin", "B000FC0SIS")]


def test_values_that_do_not_normalize_are_dropped():
    assert (
        identifier_pairs(
            isbn13=["not-a-real-isbn"],
            asin=["!!!"],
            goodreads_id=["abc"],
            oclc=["***"],
            lccn=["///"],
        )
        == []
    )


def test_duplicate_values_collapse_to_one_pair():
    # 9780306406157 also derives an isbn10 form; the duplication being tested
    # is the repeated isbn13 input collapsing rather than doubling that pair.
    assert identifier_pairs(isbn13=["9780306406157", "9780306406157"]) == [
        ("isbn10", "0306406152"),
        ("isbn13", "9780306406157"),
    ]


def test_a_plain_title_has_no_derived_variants():
    v = query_title_variants("The Great Gatsby")
    assert v.whole == {"the great gatsby", "great gatsby"}
    assert v.derived == frozenset()
    assert v.derived_subtitle is None


def test_an_inline_subtitle_yields_a_derived_title_and_subtitle():
    v = query_title_variants("THE CITY IN HISTORY: Its Origins, Its Transformations")
    assert "the city in history" in v.derived
    assert "city in history" in v.derived
    assert v.derived_subtitle == "Its Origins, Its Transformations"


def test_a_parenthetical_is_a_subtitle_cut_too():
    v = query_title_variants("Fahrenheit 451 (Ballantine)")
    assert v.derived == {"fahrenheit 451"}
    assert v.derived_subtitle == "Ballantine"


def test_a_degenerate_title_has_no_variants():
    v = query_title_variants("!!!")
    assert v.whole == frozenset() and v.derived == frozenset()
