"""Classifying an author disagreement.

Comparing our stored author against Open Library's by exact fingerprint calls
16.0% of the catalogue a disagreement, and most of that is noise: `Neville,
Gary` against `gary neville` is the same person written differently. The
classifier exists to separate the classes, because they need different work --
one is a data repair, one is a better comparator, one is a modelling decision,
and one is nothing at all.

Every case below is a real pair the sweep found over 118,458 identifier-matched
books, so a change that reclassifies one of them is a change to a number
somebody has already acted on.
"""

from __future__ import annotations

import pytest

from openlibrary.audit.authors import classify_disagreement


@pytest.mark.parametrize(
    ("ours", "theirs", "expected"),
    [
        # The Herb Gold class: a real person replaced by a different person who
        # happens to share a surname. 10,607 books, the only class that is
        # unambiguously a data repair.
        (["paul auster"], ["sara auster", "jessica orkin"], "surname_collision"),
        (["mahatma gandhi"], ["rajmohan gandhi"], "surname_collision"),
        (["ann coulter"], ["catherine coulter", "catherine r coulter"], "surname_collision"),
        (["s a barnes"], ["roy barnes"], "surname_collision"),
        # A middle initial or a dropped given name. Same person; the comparator
        # needs to know that, our data does not need fixing.
        (["irvin d yalom"], ["irvin yalom", "smedley butler"], "name_subset"),
        (["charles p chiniquy"], ["charles chiniquy"], "name_subset"),
        (["mao"], ["mao tse tung", "tse tung mao"], "name_subset"),
        # Surname-first, or a comma the importer kept. Pure formatting.
        (["neville gary"], ["gary neville"], "name_order"),
        (["brian davies"], ["davies brian"], "name_order"),
        # Nothing in common. Usually an editor or an anthology contributor
        # rather than a wrong name -- a modelling question, not corruption.
        (["stephen greenblatt"], ["guglielmo shakespeare", "szekspir william"], "unrelated"),
        (["paizo staff"], ["jeff quick", "colin mccomb"], "unrelated"),
        # We stored no author at all, under a name that looks like one.
        (["unknown"], ["crossway bibles", "esv bibles"], "placeholder"),
        (["anonymous"], ["bible", "gustave dore"], "placeholder"),
    ],
)
def test_each_disagreement_class_is_recognised(ours, theirs, expected):
    assert classify_disagreement(ours, theirs) == expected


def test_a_shared_initial_is_not_a_surname_collision():
    """`s` is shared, but a single letter is not evidence of anything. Without
    this the initial-heavy names in the catalogue would all read as
    collisions and inflate the only number that means "repair this"."""
    assert classify_disagreement(["s a barnes"], ["s a smith"]) == "unrelated"


def test_an_exact_match_is_not_a_disagreement_at_all():
    assert classify_disagreement(["gary neville"], ["gary neville"]) == "agrees"


def test_agreement_on_any_one_of_several_authors_counts_as_agreement():
    """Local sparsity is a known fact about our data, never evidence against a
    candidate -- we average 1.004 authors per book and OL often has more."""
    ours, theirs = ["robert shea"], ["robert shea", "robert anton wilson"]
    assert classify_disagreement(ours, theirs) == "agrees"
