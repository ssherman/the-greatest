import datetime

import pytest
from pydantic import ValidationError

from openlibrary.eval.schema import (
    IDENTITY_RULES,
    MAX_CASES,
    MIN_CASES,
    MIN_NO_MATCH_CASES,
    STRATA,
    EvalBook,
    EvalCandidate,
    EvalCase,
    EvalLabel,
)


def _book(**overrides) -> EvalBook:
    defaults = dict(
        book_id=48213,
        title="The Golden Apple",
        subtitle=None,
        author_names=["Robert Shea", "Robert Anton Wilson"],
        first_published_year=1975,
        isbn13=["9780440313427"],
        isbn10=[],
        asin=[],
        goodreads_id=["11207"],
        existing_ol_work_keys=["OL15331408W"],
        existing_ol_author_keys=[],
    )
    defaults.update(overrides)
    return EvalBook(**defaults)


def _label(**overrides) -> EvalLabel:
    defaults = dict(
        verdict="match",
        work_key="OL8384219W",
        identity_rule="same_work",
        rationale="Same title and both authors; the omnibus is a different work.",
        labeled_at=datetime.date(2026, 9, 2),
        labeled_against_dump_date="2026-07-31",
    )
    defaults.update(overrides)
    return EvalLabel(**defaults)


def test_strata_quotas_sum_into_the_target_range():
    total = sum(STRATA.values())
    assert MIN_CASES <= total <= MAX_CASES


def test_the_strata_cover_every_failure_mode_named_in_the_design():
    # A random sample is 90% easy cases; the set is stratified on purpose.
    assert {
        "shared_key_collision",
        "stale_ol_key",
        "easy_baseline",
        "high_frequency_title",
        "non_latin_title",
        "degenerate_title",
        "no_popularity_signal",
        "pseudonym_or_alt_name",
        "anthology_or_collection",
        "author_less_work",
        "isbn_reuse",
        "no_candidates",
    } == set(STRATA)


def test_identity_rules_come_from_the_schema_identity_table():
    assert set(IDENTITY_RULES) == {
        "same_work",
        "translation",
        "revised_edition",
        "omnibus_vs_parts",
        "collection",
        "adaptation",
        "duplicate_work",
        "wrong_data",
        "not_in_open_library",
    }


def test_a_match_verdict_requires_a_work_key():
    with pytest.raises(ValidationError):
        _label(verdict="match", work_key=None)


def test_a_no_match_verdict_forbids_a_work_key():
    with pytest.raises(ValidationError):
        _label(verdict="no_match", work_key="OL1W", identity_rule="not_in_open_library")


def test_a_no_match_verdict_uses_the_not_in_open_library_rule():
    label = _label(verdict="no_match", work_key=None, identity_rule="not_in_open_library")
    assert label.verdict == "no_match"


def test_a_rationale_is_always_required_and_non_trivial():
    with pytest.raises(ValidationError):
        _label(rationale="ok")


def test_found_outside_blocking_is_true_when_the_label_was_not_in_the_candidates():
    case = EvalCase(
        case_id="collision-OL15331408W-2",
        stratum="shared_key_collision",
        book=_book(),
        candidates_shown=[
            EvalCandidate(work_key="OL15331408W", rules=["existing_key"]),
        ],
        label=_label(work_key="OL8384219W"),
    )
    # The labeler typed a key no rule produced. This is the ONLY way a recall
    # failure can ever show up in the metrics.
    assert case.found_outside_blocking is True


def test_found_outside_blocking_is_false_when_the_label_was_shown():
    case = EvalCase(
        case_id="collision-OL15331408W-1",
        stratum="shared_key_collision",
        book=_book(),
        candidates_shown=[EvalCandidate(work_key="OL8384219W", rules=["author_title_fp"])],
        label=_label(work_key="OL8384219W"),
    )
    assert case.found_outside_blocking is False


def test_found_outside_blocking_is_false_for_a_no_match():
    case = EvalCase(
        case_id="none-1",
        stratum="no_candidates",
        book=_book(),
        candidates_shown=[],
        label=_label(verdict="no_match", work_key=None, identity_rule="not_in_open_library"),
    )
    assert case.found_outside_blocking is False


def test_an_unknown_stratum_is_rejected():
    with pytest.raises(ValidationError):
        EvalCase(
            case_id="x",
            stratum="made_up",
            book=_book(),
            candidates_shown=[],
            label=_label(),
        )


def test_a_minimum_number_of_negatives_is_declared():
    # Without negatives the false-merge rate -- the one metric to watch, because
    # a wrong merge destroys data -- cannot be computed at all.
    assert MIN_NO_MATCH_CASES >= 20
