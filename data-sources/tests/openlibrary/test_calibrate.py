"""Tests for offline weight calibration.

`search_weights` and `objective` are exercised on hand-built `PreparedCase`s
(no artifact, no DuckDB connection -- `evaluate` is pure Python, per ruling
R47). The false-merge scenario below is constructed to FORCE the hill-climb
to find a real fix, not merely to call the function and hope: with the base
(all-equal) weights, one candidate is a genuine false merge; the objective
after search must be strictly better than before, which can only happen if
`search_weights` actually found and kept a decision-flipping move.
"""

import datetime
import json

from openlibrary.eval.calibrate import (
    equal_weights,
    feature_presence,
    objective,
    search_weights,
    splink_weights,
    split_cases,
)
from openlibrary.eval.harness import Metrics, PreparedCandidate, PreparedCase, evaluate
from openlibrary.eval.schema import EvalBook, EvalCase, EvalLabel
from openlibrary.matcher.features import FEATURES
from openlibrary.matcher.scorer import Weights


def _case(case_id: str, stratum: str) -> EvalCase:
    return EvalCase(
        case_id=case_id,
        stratum=stratum,
        book=EvalBook(book_id=1, title="T"),
        candidates_shown=[],
        label=EvalLabel(
            verdict="no_match",
            work_key=None,
            identity_rule="not_in_open_library",
            rationale="Nothing in Open Library corresponds to this book.",
            labeled_at=datetime.date(2026, 9, 2),
            labeled_against_dump_date="2026-07-31",
        ),
    )


def test_split_is_stratified_and_deterministic():
    cases = [_case(f"a-{i}", "easy_baseline") for i in range(10)]
    cases += [_case(f"b-{i}", "isbn_reuse") for i in range(10)]
    train_a, test_a = split_cases(cases, seed=1, train_fraction=0.6)
    train_b, test_b = split_cases(cases, seed=1, train_fraction=0.6)
    assert [c.case_id for c in train_a] == [c.case_id for c in train_b]
    assert [c.case_id for c in test_a] == [c.case_id for c in test_b]
    for stratum in ("easy_baseline", "isbn_reuse"):
        assert sum(1 for c in train_a if c.stratum == stratum) == 6
        assert sum(1 for c in test_a if c.stratum == stratum) == 4


def test_split_puts_every_case_in_exactly_one_side():
    cases = [_case(f"a-{i}", "easy_baseline") for i in range(10)]
    train, test = split_cases(cases, seed=7)
    assert len({c.case_id for c in train} & {c.case_id for c in test}) == 0
    assert len(train) + len(test) == len(cases)


def test_a_matcher_that_abstains_on_everything_scores_badly():
    # No accepts means a perfect false-merge rate and zero value. The objective
    # must not reward it.
    abstainer = Metrics(
        n_cases=100,
        n_accepted=0,
        false_merge_rate=0.0,
        abstention_rate=1.0,
        precision_at_accept=0.0,
    )
    working = Metrics(
        n_cases=100,
        n_accepted=70,
        false_merge_rate=0.01,
        abstention_rate=0.2,
        precision_at_accept=0.99,
    )
    assert objective(working, min_accept_rate=0.3) > objective(abstainer, min_accept_rate=0.3)


def test_a_false_merge_costs_more_than_an_abstention():
    merging = Metrics(
        n_cases=100,
        n_accepted=80,
        false_merge_rate=0.10,
        abstention_rate=0.1,
        precision_at_accept=0.90,
    )
    cautious = Metrics(
        n_cases=100,
        n_accepted=50,
        false_merge_rate=0.00,
        abstention_rate=0.4,
        precision_at_accept=1.00,
    )
    assert objective(cautious, min_accept_rate=0.3) > objective(merging, min_accept_rate=0.3)


def test_a_false_reject_costs_more_than_it_would_if_ignored():
    """R53: `objective` must charge for `false_reject_rate` -- otherwise a
    search is free to drive the abstain band into reject (a true match
    silently becomes a rejected, duplicate-creating no-match) since nothing
    else in the formula notices."""
    no_false_rejects = Metrics(
        n_cases=100,
        n_accepted=60,
        false_merge_rate=0.02,
        false_reject_rate=0.0,
        abstention_rate=0.2,
        precision_at_accept=0.95,
    )
    some_false_rejects = no_false_rejects.model_copy(update={"false_reject_rate": 0.5})
    assert objective(no_false_rejects, min_accept_rate=0.3) > objective(
        some_false_rejects, min_accept_rate=0.3
    )


def test_a_false_reject_costs_more_than_an_abstention():
    false_rejecting = Metrics(
        n_cases=100,
        n_accepted=60,
        false_merge_rate=0.02,
        false_reject_rate=0.1,
        abstention_rate=0.0,
        precision_at_accept=0.95,
    )
    abstaining = false_rejecting.model_copy(
        update={"false_reject_rate": 0.0, "abstention_rate": 0.1}
    )
    assert objective(abstaining, min_accept_rate=0.3) > objective(
        false_rejecting, min_accept_rate=0.3
    )


# ---------------------------------------------------------------------------
# search_weights on hand-built PreparedCases (ruling R47: it consumes prepared
# cases and never touches DuckDB, so tests build the shape directly).
# ---------------------------------------------------------------------------


def test_equal_weights_validates_and_covers_every_feature():
    """R55: `equal_weights()` is the design's placeholder, built in code --
    not read from `weights.json`, which this module's own CLI overwrites on
    every run. It must be a valid `Weights` (the `feature_weights` validator
    runs) and declare exactly the keys in `FEATURES`."""
    weights = equal_weights()
    assert isinstance(weights, Weights)
    assert weights.calibrated is False
    assert set(weights.feature_weights) == set(FEATURES)


def _values(**present: float) -> dict[str, float | None]:
    """A full 9-key feature dict, as `features.extract` always returns, with
    every feature not passed explicitly left absent (None)."""
    return {name: present.get(name) for name in FEATURES}


def _strong_match(work_key: str, popularity: float) -> PreparedCandidate:
    return PreparedCandidate(
        work_key=work_key,
        rules=["title_fp"],
        values=_values(
            title_similarity=1.0,
            title_variant_exact=1.0,
            author_overlap=1.0,
            author_name_similarity=1.0,
            year_agreement=1.0,
            identifier_agreement=1.0,
            popularity_prior=popularity,
        ),
    )


def _weak_distractor(work_key: str, popularity: float) -> PreparedCandidate:
    return PreparedCandidate(
        work_key=work_key,
        rules=["title_fp"],
        values=_values(title_similarity=0.5, title_variant_exact=0.0, popularity_prior=popularity),
    )


def _forced_false_merge_prepared() -> list[PreparedCase]:
    """Four hand-built cases, no artifact required.

    Two clean matches the matcher must keep accepting (they anchor the
    accept-rate floor and give the search something to protect). One case
    whose only surfaced candidate is a REAL false merge under the base
    (all-weights-equal) scorer: its lone identity feature is
    `subtitle_agreement=1.0` -- a title feature, so R58's identity guard
    lets it through -- which alone scores 1.0/1.1 = 0.909 and clears the
    0.9 accept threshold with no runner-up. (It was `language_agreement`
    before R58; language is no longer identity evidence and abstains on its
    own, which is the guard doing its job, not a false merge to fix.) One
    clean true negative with no candidates at all.

    With base weights this scores: precision 0.667, false_merge_rate 0.333 --
    a bad objective, dominated by FALSE_MERGE_COST. There IS a reachable fix
    within a single hill-climb step -- either lowering `subtitle_agreement`'s
    weight enough to drop the false merge's score under 0.9, or raising
    `accept_threshold` just past it -- and both cost nothing on the two clean
    matches, whose margin over the base threshold is far larger, so a real
    search must find one of them.
    """
    good_1 = PreparedCase(
        case_id="good-1",
        stratum="easy_baseline",
        expected_work_key="OL1A",
        expected_verdict="match",
        candidates=[_strong_match("OL1A", 0.2), _weak_distractor("OL1B", 0.3)],
    )
    good_2 = PreparedCase(
        case_id="good-2",
        stratum="easy_baseline",
        expected_work_key="OL2A",
        expected_verdict="match",
        candidates=[_strong_match("OL2A", 0.2), _weak_distractor("OL2B", 0.3)],
    )
    false_merge = PreparedCase(
        case_id="spurious-1",
        stratum="no_candidates",
        expected_work_key=None,
        expected_verdict="no_match",
        candidates=[
            PreparedCandidate(
                work_key="OL3X",
                rules=["author_shelf"],
                values=_values(subtitle_agreement=1.0, popularity_prior=0.0),
            )
        ],
    )
    clean_negative = PreparedCase(
        case_id="clean-negative-1",
        stratum="no_candidates",
        expected_work_key=None,
        expected_verdict="no_match",
        candidates=[],
    )
    return [good_1, good_2, false_merge, clean_negative]


def test_search_weights_finds_a_real_fix_for_a_forced_false_merge():
    prepared = _forced_false_merge_prepared()
    base = equal_weights()

    base_metrics, _ = evaluate(prepared, base)
    base_score = objective(base_metrics, min_accept_rate=0.3)
    assert base_metrics.false_merge_rate > 0, "the scenario must start with a real false merge"

    searched, train_score = search_weights(prepared, base=base, iterations=2000, seed=20260901)

    assert isinstance(searched, Weights)
    assert train_score > base_score

    searched_metrics, _ = evaluate(prepared, searched)
    assert train_score == objective(searched_metrics, min_accept_rate=0.3)
    assert searched_metrics.false_merge_rate < base_metrics.false_merge_rate, (
        "search_weights must have actually flipped the forced false merge, not merely "
        "reported a higher score"
    )


def test_search_weights_never_returns_worse_than_the_base():
    prepared = _forced_false_merge_prepared()
    base = equal_weights()
    base_metrics, _ = evaluate(prepared, base)
    base_score = objective(base_metrics, min_accept_rate=0.3)

    _, train_score = search_weights(prepared, base=base, iterations=50, seed=1)
    assert train_score >= base_score


def test_search_weights_is_deterministic_given_a_seed():
    prepared = _forced_false_merge_prepared()
    base = equal_weights()

    weights_a, score_a = search_weights(prepared, base=base, iterations=300, seed=42)
    weights_b, score_b = search_weights(prepared, base=base, iterations=300, seed=42)

    assert weights_a.model_dump() == weights_b.model_dump()
    assert score_a == score_b


def test_search_weights_output_round_trips_through_weights_json():
    """weights.json written by calibration must load through `load_weights()`
    -- the `feature_weights` validator has to see exactly the declared
    FEATURES keys, no more, no fewer, after a JSON round trip."""
    prepared = _forced_false_merge_prepared()
    base = equal_weights()

    searched, _ = search_weights(prepared, base=base, iterations=100, seed=7)

    round_tripped = Weights.model_validate(json.loads(json.dumps(searched.model_dump())))
    assert round_tripped == searched
    assert set(round_tripped.feature_weights) == set(FEATURES)


# ---------------------------------------------------------------------------
# Ruling R61: a feature no training pair exercised has weight 0.0, not "1.0,
# untouched". `_forced_false_merge_prepared` never gives `language_agreement`
# a value (and `subtitle_agreement` only on the forced false merge), so it is
# the natural specimen.
# ---------------------------------------------------------------------------


def test_feature_presence_is_the_fraction_of_candidate_values_present():
    prepared = _forced_false_merge_prepared()
    presence = feature_presence(prepared)
    # 5 candidates in all: two strong matches, two weak distractors, one
    # forced false merge.
    assert set(presence) == set(FEATURES)
    assert presence["title_similarity"] == 0.8  # every candidate but the false merge
    assert presence["subtitle_agreement"] == 0.2  # the false merge only
    assert presence["language_agreement"] == 0.0
    assert presence["popularity_prior"] == 1.0


def test_feature_presence_with_no_candidates_is_zero_everywhere():
    empty = PreparedCase(
        case_id="e", stratum="s", expected_work_key=None, expected_verdict="no_match"
    )
    assert feature_presence([empty]) == dict.fromkeys(FEATURES, 0.0)
    assert feature_presence([]) == dict.fromkeys(FEATURES, 0.0)


def test_an_unexercised_feature_is_pinned_to_zero_and_never_moved():
    prepared = _forced_false_merge_prepared()
    base = equal_weights()
    assert base.feature_weights["language_agreement"] == 1.0  # the base does NOT say 0

    searched, _ = search_weights(prepared, base=base, iterations=2000, seed=20260901)

    assert searched.feature_weights["language_agreement"] == 0.0
    # And the base is untouched: the pin happens on the search's own copy.
    assert base.feature_weights["language_agreement"] == 1.0


def test_an_unexercised_feature_stays_at_zero_across_seeds():
    """If `language_agreement` were still a knob, some seed among these would
    move it off 0.0 with ~2000 draws over 12 knobs -- one seed passing by
    luck is not evidence that it was removed from the knob list."""
    prepared = _forced_false_merge_prepared()
    for seed in (1, 2, 3, 20260901):
        searched, _ = search_weights(prepared, base=equal_weights(), iterations=400, seed=seed)
        assert searched.feature_weights["language_agreement"] == 0.0, seed


def test_an_exercised_feature_can_still_move():
    """The control: presence > 0 keeps a feature in the knob list. Over 2000
    steps with 11 knobs at least one present feature weight leaves 1.0."""
    prepared = _forced_false_merge_prepared()
    searched, _ = search_weights(prepared, base=equal_weights(), iterations=2000, seed=20260901)
    moved = [
        name
        for name in FEATURES
        if name != "language_agreement" and searched.feature_weights[name] != 1.0
    ]
    assert moved, "no exercised feature weight moved in 2000 steps"


def test_equal_weights_declares_no_method():
    assert equal_weights().method is None


def test_splink_weights_returns_none_when_the_extra_is_unavailable_or_the_shape_mismatches():
    """Whether the `calibration` extra is installed or not, `splink_weights`
    must return `None` from `_forced_false_merge_prepared()`'s tiny sample:
    without the extra it never gets past the import; with it installed, the
    one concrete attempt (see the module docstring) fails for the documented,
    structural reason -- PreparedCase carries no raw per-record column Splink
    could select from both sides of the pair. Either way the caller sees a
    plain `None`, never a crash."""
    assert splink_weights(_forced_false_merge_prepared()) is None
