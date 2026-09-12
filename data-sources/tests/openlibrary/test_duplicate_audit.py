"""Two of our Book rows on one Open Library work.

`Books::Book` is work-level, so two rows resolving to the same OL work are the
same book twice -- a merge candidate. This finds them without looking at the
title, which is what makes it different from the (author, title) grouping in
`test_title_audit.py`: `Der Grosse Crash 1929` and `The Great Crash, 1929` are
one book under two titles and no title comparison will ever pair them.

The counts this produces are a candidate list, never a verdict. Open Library
conflates works of its own -- OL16825084W holds three different Veronica Roth
novellas -- so a shared work is evidence, and the confidence rule below is what
keeps the evidence worth acting on.
"""

from __future__ import annotations

from openlibrary.audit.duplicates import confident_duplicate_groups


def test_two_rows_whose_only_claim_is_one_shared_work_are_a_group():
    """Books #76231 and #76373, both `Emergency` by Kathleen Alcott -- the
    second stored with a U+202F narrow no-break space in the author name, which
    made the importer create a second Author and a second Book."""
    groups = confident_duplicate_groups({76231: {"OL29333094W"}, 76373: {"OL29333094W"}})

    assert groups == {"OL29333094W": [76231, 76373]}


def test_a_row_claiming_several_works_is_not_confident_evidence():
    """Book #14079, `The Great Crash, 1929`, resolves to four OL works at once.
    Sharing one of them with another row says little -- OL holds that book nine
    times over, so the overlap is nearly free."""
    groups = confident_duplicate_groups(
        {
            14079: {"OL12578W", "OL12547W", "OL21242875W", "OL19642549W"},
            999001: {"OL12578W"},
        }
    )

    assert groups == {}


def test_a_work_only_one_row_claims_is_not_a_duplicate():
    assert confident_duplicate_groups({1: {"OL1W"}, 2: {"OL2W"}}) == {}


def test_rows_open_library_cannot_place_are_ignored_not_grouped():
    """Book #168338, the German `Der Grosse Crash 1929`, resolves to nothing --
    its ISBN is not in OL. It really is a duplicate of #14079 and this method
    cannot see it, which is why the count is a floor."""
    assert confident_duplicate_groups({168338: set(), 14079: set()}) == {}


def test_a_group_larger_than_a_pair_is_kept_whole():
    """OL16825084W collects `Four`, `The Traitor` and `The Transfer`. All three
    rows resolve to it alone, so the rule admits them -- correctly by its own
    terms, and wrongly in fact, because the conflation is Open Library's. The
    output is a candidate list for review, not a merge instruction."""
    groups = confident_duplicate_groups(
        {51287: {"OL16825084W"}, 71020: {"OL16825084W"}, 71023: {"OL16825084W"}}
    )

    assert groups == {"OL16825084W": [51287, 71020, 71023]}
