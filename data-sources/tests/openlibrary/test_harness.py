"""Tests for the evaluation harness: run the matcher over labeled cases.

Uses the session-scoped `fixture_artifact` (see tests/conftest.py) rather than
building a fresh artifact per test. The `authored_unique_works` discovery query
is pinned to a shape the committed fixture corpus is known to hold -- a
uniquely-fingerprinted, authored title -- with an explicit `ORDER BY` so the
selection is deterministic (ruling R43: with `preserve_insertion_order=false`,
an unordered `LIMIT` is flaky).

The false-merge and abstention tests are constructed to FORCE their outcome
(same title and authors as a real fixture work, mislabeled) rather than
asserting inside an `if` that might not execute -- a conditional assertion
passes vacuously when nothing is accepted, silently stopping being a test of
anything.
"""

from __future__ import annotations

import contextlib
import datetime

import pytest

from common.normalize import MIN_BLOCKING_FP_LENGTH
from openlibrary.eval.harness import Metrics, evaluate, prepare, run
from openlibrary.eval.schema import EvalBook, EvalCandidate, EvalCase, EvalLabel
from openlibrary.matcher.scorer import load_weights
from openlibrary.pipeline.duck import connect


@pytest.fixture(scope="module")
def authored_unique_works(fixture_artifact):
    """First 12 works (by work_key) with a unique, fingerprintable title and
    at least one author -- the shape both the metrics tests and the
    deterministic false-merge tests below build their cases from."""
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        rows = con.execute(
            f"""
            SELECT w.work_key, w.title, list(DISTINCT a.name) AS names
            FROM '{fixture_artifact.table("works")}' w
            JOIN '{fixture_artifact.table("work_authors")}' wa USING (work_key)
            JOIN '{fixture_artifact.table("authors")}' a USING (author_key)
            WHERE w.title_fp <> '' AND length(w.title_fp) >= {MIN_BLOCKING_FP_LENGTH}
              AND w.title_fp_freq = 1 AND a.name IS NOT NULL
            GROUP BY w.work_key, w.title
            ORDER BY w.work_key
            LIMIT 12
            """
        ).fetchall()
    assert len(rows) >= 12, (
        "fixture corpus lost the uniquely-titled, authored works this test needs"
    )
    return [(work_key, title, list(names or [])) for work_key, title, names in rows]


@pytest.fixture(scope="module")
def work_a(authored_unique_works):
    return authored_unique_works[0]


@pytest.fixture(scope="module")
def work_b(authored_unique_works):
    return authored_unique_works[1]


@pytest.fixture(scope="module")
def cases(authored_unique_works):
    built = []
    for index, (work_key, title, names) in enumerate(authored_unique_works[:10], start=1):
        built.append(
            EvalCase(
                case_id=f"easy_baseline-{index:03d}",
                stratum="easy_baseline",
                book=EvalBook(book_id=index, title=title, author_names=list(names)),
                candidates_shown=[EvalCandidate(work_key=work_key, rules=["title_fp"])],
                label=EvalLabel(
                    verdict="match",
                    work_key=work_key,
                    identity_rule="same_work",
                    rationale="Constructed from the artifact for the harness test.",
                    labeled_at=datetime.date(2026, 9, 2),
                    labeled_against_dump_date="2026-07-31",
                ),
            )
        )
    built.append(
        EvalCase(
            case_id="no_candidates-001",
            stratum="no_candidates",
            book=EvalBook(book_id=999, title="Zzzz Nothing Like This Exists Anywhere"),
            candidates_shown=[],
            label=EvalLabel(
                verdict="no_match",
                work_key=None,
                identity_rule="not_in_open_library",
                rationale="Checked Open Library by hand; nothing corresponds.",
                labeled_at=datetime.date(2026, 9, 2),
                labeled_against_dump_date="2026-07-31",
            ),
        )
    )
    return built


def test_harness_returns_metrics_and_one_outcome_per_case(fixture_artifact, cases):
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        metrics, outcomes = run(con, fixture_artifact, cases, load_weights())
    assert isinstance(metrics, Metrics)
    assert len(outcomes) == len(cases)
    assert metrics.n_cases == len(cases)


def test_candidate_recall_is_reported_at_five_ten_and_fifty(fixture_artifact, cases):
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        metrics, _ = run(con, fixture_artifact, cases, load_weights())
    assert set(metrics.candidate_recall) == {5, 10, 50}
    for value in metrics.candidate_recall.values():
        assert 0.0 <= value <= 1.0


def test_recall_at_fifty_is_at_least_recall_at_five(fixture_artifact, cases):
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        metrics, _ = run(con, fixture_artifact, cases, load_weights())
    assert metrics.candidate_recall[50] >= metrics.candidate_recall[5]


def test_a_false_merge_is_an_accept_on_the_wrong_work(fixture_artifact, work_a, work_b):
    """Book carries A's title and authors; the label names B. With
    uncalibrated weights (all feature weights 1.0) the matcher accepts A on
    an exact title/author match -- a real accept on the wrong work, forced
    to happen rather than hoped for."""
    a_key, a_title, a_authors = work_a
    b_key, _, _ = work_b
    case = EvalCase(
        case_id="forced_false_merge-a_onto_b",
        stratum="easy_baseline",
        book=EvalBook(book_id=9001, title=a_title, author_names=a_authors),
        candidates_shown=[EvalCandidate(work_key=b_key, rules=["title_fp"])],
        label=EvalLabel(
            verdict="match",
            work_key=b_key,
            identity_rule="same_work",
            rationale="Constructed to force a false merge: the book's data matches a "
            "different work than the one this label names.",
            labeled_at=datetime.date(2026, 9, 2),
            labeled_against_dump_date="2026-07-31",
        ),
    )
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        _, outcomes = run(con, fixture_artifact, [case], load_weights())
    outcome = outcomes[0]
    assert outcome.decision.verdict == "accept", (
        f"expected the uncalibrated matcher to accept {a_key!r} on its own exact "
        f"title/author match; got {outcome.decision.verdict!r} ({outcome.decision.reason})"
    )
    assert outcome.decision.work_key == a_key
    assert outcome.false_merge is True
    assert outcome.correct is False


def test_a_no_match_case_accepted_onto_any_work_counts_as_a_false_merge(fixture_artifact, work_a):
    """Book carries A's title and authors; the label says no_match. The
    matcher still accepts A -- and any accept on a no_match case is a false
    merge by definition, regardless of which work it lands on."""
    a_key, a_title, a_authors = work_a
    case = EvalCase(
        case_id="forced_false_merge-no_match",
        stratum="no_candidates",
        book=EvalBook(book_id=9002, title=a_title, author_names=a_authors),
        candidates_shown=[],
        label=EvalLabel(
            verdict="no_match",
            work_key=None,
            identity_rule="not_in_open_library",
            rationale="Constructed to force a false merge: the book's data exactly "
            "matches a real work despite being labeled no_match.",
            labeled_at=datetime.date(2026, 9, 2),
            labeled_against_dump_date="2026-07-31",
        ),
    )
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        _, outcomes = run(con, fixture_artifact, [case], load_weights())
    outcome = outcomes[0]
    assert outcome.decision.verdict == "accept", (
        f"expected the uncalibrated matcher to accept {a_key!r} on its own exact "
        f"title/author match; got {outcome.decision.verdict!r} ({outcome.decision.reason})"
    )
    assert outcome.false_merge is True


def test_abstention_is_counted_as_neither_correct_nor_a_false_merge(fixture_artifact, work_a):
    """An `ambiguous`-labelled case whose book carries A's own data: whatever
    the matcher decides, `correct` and `false_merge` must be consistent with
    that decision -- correct means it abstained, false_merge means it
    accepted -- checked deterministically rather than only when one branch
    happens to fire."""
    a_key, a_title, a_authors = work_a
    case = EvalCase(
        case_id="forced_ambiguous-a",
        stratum="anthology_or_collection",
        book=EvalBook(book_id=9003, title=a_title, author_names=a_authors),
        candidates_shown=[EvalCandidate(work_key=a_key, rules=["title_fp"])],
        label=EvalLabel(
            verdict="ambiguous",
            work_key=a_key,
            identity_rule="duplicate_work",
            rationale="Constructed ambiguous case: for an ambiguous label, correctness "
            "means abstaining regardless of whether the matcher's top pick is the "
            "labeled work.",
            labeled_at=datetime.date(2026, 9, 2),
            labeled_against_dump_date="2026-07-31",
        ),
    )
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        _, outcomes = run(con, fixture_artifact, [case], load_weights())
    outcome = outcomes[0]
    assert outcome.false_merge is (outcome.decision.verdict == "accept")
    assert outcome.correct is (outcome.decision.verdict == "abstain")


def test_metrics_are_all_finite_even_with_no_accepts(fixture_artifact):
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        metrics, _ = run(con, fixture_artifact, [], load_weights())
    assert metrics.n_cases == 0
    assert metrics.precision_at_accept == 0.0
    assert metrics.false_merge_rate == 0.0


# The whole point of the prepare/evaluate split (Task 27's calibration search
# calls prepare once per split and evaluate thousands of times) is that it
# must not change what run() measures. This is the equivalence pin.
def test_run_equals_evaluate_of_prepare(fixture_artifact, cases):
    weights = load_weights()
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        run_metrics, run_outcomes = run(con, fixture_artifact, cases, weights)
        prepared = prepare(con, fixture_artifact, cases)
        eval_metrics, eval_outcomes = evaluate(prepared, weights)

    assert run_metrics.model_dump() == eval_metrics.model_dump()
    assert [o.model_dump() for o in run_outcomes] == [o.model_dump() for o in eval_outcomes]


def test_evaluate_needs_no_connection(fixture_artifact, cases):
    weights = load_weights()
    con = connect(fixture_artifact, memory_limit="1GB")
    prepared = prepare(con, fixture_artifact, cases)
    con.close()

    # Must not touch DuckDB: the connection above is already closed. A
    # `prepare` that leaked a `con` reference into `evaluate` would raise here.
    metrics, outcomes = evaluate(prepared, weights)
    assert metrics.n_cases == len(cases)
    assert len(outcomes) == len(cases)


def test_evaluate_with_different_weights_changes_only_scoring(fixture_artifact, cases):
    weights = load_weights()
    impossible = weights.model_copy(update={"accept_threshold": 1.01})

    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        prepared = prepare(con, fixture_artifact, cases)

    baseline_metrics, _ = evaluate(prepared, weights)
    starved_metrics, _ = evaluate(prepared, impossible)

    # Recall is a property of blocking, not weights (R45's invariant): the
    # same `prepared` re-scored with a threshold nothing can clear must still
    # report identical candidate recall, even though nothing gets accepted.
    assert starved_metrics.n_accepted == 0
    assert starved_metrics.candidate_recall == baseline_metrics.candidate_recall
