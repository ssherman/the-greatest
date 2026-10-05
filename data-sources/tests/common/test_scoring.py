import pytest

from common.scoring import (
    DERIVED_TITLE_FACTOR,
    TitleComparison,
    compare_titles,
    fuzzy_similarity,
    identifier_agreement,
    set_overlap,
    year_agreement,
)


def test_identical_titles_score_one():
    assert fuzzy_similarity("the great gatsby", "the great gatsby") == pytest.approx(1.0)


def test_reordered_titles_still_score_high():
    # Measured: Jaccard handled reordering (0.929) and failed on subtitles (0.44);
    # Jaro-Winkler did the reverse. Taking the max of several comparators is why
    # both cases work without fuzzy machinery in the blocking layer.
    assert fuzzy_similarity("gatsby the great", "the great gatsby") > 0.85


def test_subtitled_titles_still_score_high():
    assert fuzzy_similarity("ulysses a novel", "ulysses") > 0.7


def test_unrelated_titles_score_low():
    assert fuzzy_similarity("the great gatsby", "war and peace") < 0.4


def test_fuzzy_similarity_is_none_when_either_side_is_empty():
    # An empty fingerprint is ABSENCE, not disagreement (ruling R40): a
    # punctuation-only title must not score as if it disagreed with a real one.
    assert fuzzy_similarity("", "ulysses") is None
    assert fuzzy_similarity("ulysses", "") is None


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


def _cmp(query, work_variants):
    from common.normalize import query_title_variants

    v = query_title_variants(query)
    return compare_titles(v.whole, v.derived, work_variants)


def test_a_sequel_is_no_longer_a_perfect_title_match():
    c = _cmp("Dune", ["children of dune", "children of dune", "children of dune"])
    assert c.similarity < 0.6
    assert c.exact == 0.0
    assert c.containment is True


def test_a_longer_title_containing_ours_is_far_from_perfect():
    work = ["the road to wigan pier", "the road to wigan pier", "road to wigan pier"]
    assert _cmp("The Road", work).similarity < 0.6


def test_one_shared_word_is_not_a_near_match():
    assert (
        _cmp("The Wife", ["the interestings", "the interestings", "interestings"]).similarity < 0.6
    )


def test_a_work_subtitle_is_matched_through_its_stored_variant():
    c = _cmp("Emma", ["emma a novel", "emma", "emma a novel"])
    assert c.similarity == 1.0 and c.exact == 1.0


def test_an_inline_query_subtitle_matches_through_a_derived_variant():
    work = ["the city in history", "the city in history", "city in history"]
    c = _cmp("THE CITY IN HISTORY: Its Origins", work)
    assert c.exact == 1.0
    assert c.similarity == DERIVED_TITLE_FACTOR


def test_full_title_match_outranks_a_subtitle_dropped_match():
    own = _cmp(
        "Star Wars: A New Hope", ["star wars a new hope", "star wars", "star wars a new hope"]
    )
    other = _cmp("Star Wars: A New Hope", ["star wars", "star wars", "star wars"])
    assert own.similarity == 1.0
    assert other.similarity == DERIVED_TITLE_FACTOR


def test_an_empty_side_is_absence_not_disagreement():
    absent = TitleComparison(similarity=None, exact=None, containment=False)
    assert _cmp("!!!", ["dune", "dune", "dune"]) == absent
    assert compare_titles(["dune"], [], ["", "", ""]) == absent


def test_containment_is_false_without_a_strict_subset():
    assert (
        _cmp("The Wife", ["the interestings", "the interestings", "interestings"]).containment
        is False
    )
    assert _cmp("Dune", ["dune", "dune", "dune"]).containment is False


def test_reordered_titles_still_match():
    work = ["the great gatsby", "the great gatsby", "great gatsby"]
    assert _cmp("Gatsby the Great", work).similarity > 0.85
