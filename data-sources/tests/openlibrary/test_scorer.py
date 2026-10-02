import json

import pytest

from openlibrary.matcher.blocking import BlockingQuery
from openlibrary.matcher.features import FEATURES, WorkView, conflicts, extract
from openlibrary.matcher.scorer import (
    MATCHER_VERSION,
    Weights,
    load_weights,
    score_candidate,
    score_features,
)


def _work(**overrides) -> WorkView:
    defaults = dict(
        work_key="OL1W",
        title="The Great Gatsby",
        title_fp="the great gatsby",
        title_fp_nosub="the great gatsby",
        title_fp_noart="great gatsby",
        author_names=["F. Scott Fitzgerald"],
        declared_year=1925,
        min_edition_year=1925,
        modal_edition_year=1953,
    )
    defaults.update(overrides)
    return WorkView(**defaults)


def _weights_payload(**feature_weight_overrides):
    feature_weights = dict.fromkeys(FEATURES, 1.0)
    feature_weights.update(feature_weight_overrides)
    return {
        "matcher_version": MATCHER_VERSION,
        "calibrated": False,
        "calibrated_at": None,
        "feature_weights": feature_weights,
        "conflict_penalties": {"identifier": 0.35},
        "accept_threshold": 0.9,
        "reject_threshold": 0.4,
        "margin_threshold": 0.05,
    }


def _equal_weights() -> Weights:
    """The pre-calibration equal-weights `Weights`, built inline.

    NOT `load_weights()`: that now reads the real, calibrated (non-equal)
    shipped file (Task 27), so an arithmetic or decision test asserting a
    specific numeric relationship needs a fixed, known weight vector of its
    own rather than whatever `weights.json` currently holds. Only the two
    shipped-file tests directly below (and the round-trip test further down)
    are actually about the shipped file and read it via `load_weights()`.

    `popularity_prior=0.1` (not `_weights_payload()`'s bare default of 1.0
    for every key): the arithmetic below is written against the design's
    original placeholder, which always down-weighted the prior -- popularity
    is a tie-breaker, never identity evidence, and at a full weight of 1.0 a
    work with zero popularity signal (every `_work()` fixture here) drags an
    otherwise-perfect match's score down by a full unweighted term.
    """
    return Weights.model_validate(_weights_payload(popularity_prior=0.1))


def test_the_shipped_weight_file_declares_how_it_was_calibrated():
    """Task 27 (R55) calibrated `weights.json` for real: it now declares
    `calibrated=True` with a non-empty `calibrated_at` timestamp, rather than
    the pre-calibration placeholder this test used to pin (`calibrated=False`,
    `calibrated_at=None`)."""
    weights = load_weights()
    assert weights.matcher_version == MATCHER_VERSION
    assert weights.calibrated is True
    assert isinstance(weights.calibrated_at, str) and weights.calibrated_at
    assert weights.method == "random-search"
    assert set(weights.feature_weights) == set(FEATURES)


def test_every_feature_has_a_weight():
    weights = load_weights()
    assert set(weights.feature_weights) == set(FEATURES)


def test_a_perfect_match_scores_near_one():
    query = BlockingQuery(title="The Great Gatsby", author_names=["F. Scott Fitzgerald"], year=1925)
    scored = score_candidate(query, _work(), ["author_title_fp"], _equal_weights())
    assert scored.score > 0.9


def test_an_unrelated_candidate_scores_low():
    query = BlockingQuery(title="War and Peace", author_names=["Leo Tolstoy"], year=1869)
    scored = score_candidate(query, _work(), ["title_fp"], _equal_weights())
    assert scored.score < 0.4


def test_absence_is_neutral_not_negative():
    weights = _equal_weights()
    full = BlockingQuery(title="The Great Gatsby", author_names=["F. Scott Fitzgerald"], year=1925)
    thin = BlockingQuery(title="The Great Gatsby")
    # Dropping our author and year removes evidence. It must not remove SCORE:
    # local sparsity is a fact about us, not about the candidate. On equal
    # weights the real gap is ~0.028; the bug this guards against (treating
    # absence as disagreement) would widen it to ~0.37, so abs=0.05 actually
    # discriminates rather than passing on either arithmetic.
    assert score_candidate(thin, _work(), ["title_fp"], weights).score == pytest.approx(
        score_candidate(full, _work(), ["title_fp"], weights).score, abs=0.05
    )


# Identifier agreement is WORK-LEVEL (ruling R35): WorkView carries no isbn13
# field, and the evidence is `identifier_hits` -- the set of work keys
# blocking's identifier rule reached -- compared against this work's own key.
def test_an_identifier_conflict_pushes_the_score_down():
    weights = _equal_weights()
    query = BlockingQuery(title="The Great Gatsby")
    work = _work()
    clean = score_candidate(query, work, ["title_fp"], weights)
    conflicting = score_candidate(
        query, work, ["title_fp"], weights, identifier_hits=frozenset({"OL2W"})
    )
    assert conflicting.score < clean.score
    assert conflicting.conflicts == ["identifier"]
    assert clean.conflicts == []


def test_an_identifier_hit_on_this_work_raises_the_score():
    weights = _equal_weights()
    query = BlockingQuery(title="The Great Gatsby")
    work = _work()
    clean = score_candidate(query, work, ["title_fp"], weights)
    hit = score_candidate(query, work, ["title_fp"], weights, identifier_hits=frozenset({"OL1W"}))
    assert hit.score > clean.score
    assert hit.conflicts == []


# The ordering assertions above (`<`, `>`) would also pass if the conflict
# penalty did nothing and the score change came entirely from
# identifier_agreement becoming a present-but-disagreeing feature. This test
# isolates the penalty itself: when identifier_hits point elsewhere, TWO
# things change at once -- identifier_agreement flips from absent (None) to
# present-and-0.0 (which alone would lower the weighted mean), AND the 0.35
# conflict penalty is subtracted. We can't assert the total drop equals
# exactly 0.35 because of the first effect, so instead we assert the penalty
# accounts for AT LEAST 0.35 of the drop -- proving the subtraction actually
# happens rather than merely being ordered correctly by coincidence.
def test_an_identifier_conflict_penalty_is_actually_subtracted():
    weights = _equal_weights()
    query = BlockingQuery(title="The Great Gatsby")
    work = _work()
    clean = score_candidate(query, work, ["title_fp"], weights)
    conflicting = score_candidate(
        query, work, ["title_fp"], weights, identifier_hits=frozenset({"OL2W"})
    )
    assert clean.score - conflicting.score >= 0.35


def test_evidence_is_inspectable_per_feature():
    scored = score_candidate(
        BlockingQuery(title="The Great Gatsby"), _work(), ["title_fp"], _equal_weights()
    )
    # A score nobody can take apart is a score nobody can trust.
    for name, entry in scored.evidence.items():
        assert name in FEATURES
        assert "value" in entry and "weight" in entry and "contribution" in entry


def test_absent_features_appear_in_the_evidence_with_a_null_value():
    scored = score_candidate(
        BlockingQuery(title="The Great Gatsby"), _work(), ["title_fp"], _equal_weights()
    )
    assert scored.evidence["year_agreement"]["value"] is None
    assert scored.evidence["year_agreement"]["contribution"] == 0.0


def test_scores_are_bounded():
    weights = _equal_weights()
    cases = [
        (BlockingQuery(title="The Great Gatsby"), frozenset({"OL2W"})),
        (BlockingQuery(title=""), frozenset()),
    ]
    for query, identifier_hits in cases:
        scored = score_candidate(query, _work(), [], weights, identifier_hits=identifier_hits)
        assert 0.0 <= scored.score <= 1.0


# score_features is score_candidate's arithmetic extracted verbatim so the
# calibration search loop (Task 27) can re-score a prepared candidate without
# re-running extract/conflicts per weight vector. This pins them equal, field
# for field, so the extraction cannot silently drift from score_candidate.
def test_score_features_is_what_score_candidate_computes():
    weights = _equal_weights()
    query = BlockingQuery(title="The Great Gatsby", author_names=["F. Scott Fitzgerald"], year=1925)
    work = _work()
    rules = ["author_title_fp"]

    via_candidate = score_candidate(query, work, rules, weights)
    via_features = score_features(
        work.work_key, extract(query, work), conflicts(query, work), rules, weights
    )

    assert via_candidate.score == via_features.score
    assert via_candidate.evidence == via_features.evidence
    assert via_candidate.conflicts == via_features.conflicts
    assert via_candidate.rules == via_features.rules


def test_weights_round_trip_through_json(tmp_path):
    weights = load_weights()
    path = tmp_path / "w.json"
    path.write_text(weights.model_dump_json())
    assert load_weights(path) == weights
    assert json.loads(path.read_text())["matcher_version"] == MATCHER_VERSION


# A typo in weights.json must fail LOUDLY at load time (Task 27 overwrites
# this file after calibration), not silently weight the misspelled feature
# at zero and the real feature at nothing at all.
def test_an_unknown_feature_weight_key_fails_to_load():
    payload = _weights_payload()
    payload["feature_weights"]["title_similarty"] = payload["feature_weights"].pop(
        "title_similarity"
    )
    with pytest.raises(ValueError, match="title_similarty"):
        Weights.model_validate(payload)


def test_a_missing_feature_weight_key_fails_to_load():
    payload = _weights_payload()
    del payload["feature_weights"]["popularity_prior"]
    with pytest.raises(ValueError, match="popularity_prior"):
        Weights.model_validate(payload)
