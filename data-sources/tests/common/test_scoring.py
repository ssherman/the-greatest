import pytest

from common.scoring import (
    identifier_agreement,
    set_overlap,
    title_similarity,
    year_agreement,
)


def test_identical_titles_score_one():
    assert title_similarity("the great gatsby", "the great gatsby") == pytest.approx(1.0)


def test_reordered_titles_still_score_high():
    # Measured: Jaccard handled reordering (0.929) and failed on subtitles (0.44);
    # Jaro-Winkler did the reverse. Taking the max of several comparators is why
    # both cases work without fuzzy machinery in the blocking layer.
    assert title_similarity("gatsby the great", "the great gatsby") > 0.85


def test_subtitled_titles_still_score_high():
    assert title_similarity("ulysses a novel", "ulysses") > 0.7


def test_unrelated_titles_score_low():
    assert title_similarity("the great gatsby", "war and peace") < 0.4


def test_set_overlap_is_none_when_either_side_is_empty():
    # Absence is NEUTRAL, not negative: with 1.004 authors per book, a missing
    # co-author is a fact about our data, not evidence about the candidate.
    assert set_overlap(set(), {"a"}) is None
    assert set_overlap({"a"}, set()) is None


def test_set_overlap_is_the_fraction_of_the_smaller_side_that_matches():
    assert set_overlap({"a"}, {"a", "b", "c"}) == pytest.approx(1.0)
    assert set_overlap({"a", "b"}, {"a", "c"}) == pytest.approx(0.5)
    assert set_overlap({"a"}, {"b"}) == pytest.approx(0.0)


def test_year_agreement_is_none_without_a_year():
    assert year_agreement(None, 1925, 1930) is None
    assert year_agreement(1925, None, None) is None


def test_year_inside_the_evidence_range_scores_one():
    assert year_agreement(1927, 1925, 1930) == pytest.approx(1.0)


def test_year_just_outside_the_range_decays_rather_than_failing():
    near = year_agreement(1923, 1925, 1930)
    far = year_agreement(1850, 1925, 1930)
    assert 0.0 < far < near < 1.0


def test_identifier_agreement_reports_absent_when_either_side_is_empty():
    assert identifier_agreement(set(), {"9780306406157"}) == "absent"
    assert identifier_agreement({"9780306406157"}, set()) == "absent"


def test_identifier_agreement_reports_agree_on_any_overlap():
    assert identifier_agreement({"a", "b"}, {"b"}) == "agree"


def test_identifier_agreement_reports_conflict_on_disjoint_non_empty_sets():
    # The only strong NEGATIVE feature in the model.
    assert identifier_agreement({"a"}, {"b"}) == "conflict"
