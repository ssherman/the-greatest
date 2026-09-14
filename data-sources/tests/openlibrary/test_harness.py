"""Tests for the evaluation harness: run the matcher over labeled cases.

Uses the session-scoped `fixture_artifact` (see tests/conftest.py) rather than
building a fresh artifact per test. The `fixture_labelled_works` discovery
query (tests/conftest.py, shared with the gate tests) is pinned to a shape the
committed fixture corpus is known to hold -- a uniquely-fingerprinted,
authored title -- with an explicit `ORDER BY` so the selection is
deterministic (ruling R43: with `preserve_insertion_order=false`, an
unordered `LIMIT` is flaky).

The false-merge and abstention tests are constructed to FORCE their outcome
(same title and authors as a real fixture work, mislabeled) rather than
asserting inside an `if` that might not execute -- a conditional assertion
passes vacuously when nothing is accepted, silently stopping being a test of
anything.
"""

from __future__ import annotations

import contextlib
import datetime
import json

import pytest

from openlibrary.eval import harness
from openlibrary.eval.harness import (
    Metrics,
    PreparedCandidate,
    PreparedCase,
    evaluate,
    prepare,
    read_prepared_cache,
    run,
    write_prepared_cache,
)
from openlibrary.eval.schema import EvalBook, EvalCandidate, EvalCase, EvalLabel
from openlibrary.matcher.features import FEATURES
from openlibrary.matcher.scorer import MATCHER_VERSION, Weights, load_weights
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths


def _equal_weights() -> Weights:
    """The design's equal-weights placeholder, built inline -- NOT
    `load_weights()`, which reads the real calibrated file (Task 27) whose
    numbers change on every calibration run. The forced-outcome tests below
    assert what "all feature weights 1.0" does with an exact title/author
    match, so they need exactly that vector. Constructed here rather than
    imported from `openlibrary.eval.calibrate` to keep this module's imports
    to the harness under test."""
    return Weights(
        matcher_version=MATCHER_VERSION,
        calibrated=False,
        calibrated_at=None,
        feature_weights={**dict.fromkeys(FEATURES, 1.0), "popularity_prior": 0.1},
        conflict_penalties={"identifier": 0.35},
        accept_threshold=0.9,
        reject_threshold=0.4,
        margin_threshold=0.05,
    )


@pytest.fixture(scope="module")
def authored_unique_works(fixture_labelled_works):
    """See `fixture_labelled_works` in tests/conftest.py -- shared with the
    gate tests, which need a labelled set whose works the fixture artifact
    actually contains."""
    return fixture_labelled_works


@pytest.fixture(scope="module")
def work_a(authored_unique_works):
    return authored_unique_works[0]


@pytest.fixture(scope="module")
def work_b(authored_unique_works):
    return authored_unique_works[1]


@pytest.fixture(scope="module")
def cases(fixture_labelled_cases):
    return fixture_labelled_cases


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
        _, outcomes = run(con, fixture_artifact, [case], _equal_weights())
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
        _, outcomes = run(con, fixture_artifact, [case], _equal_weights())
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
    assert metrics.false_reject_rate == 0.0


def test_a_match_case_with_no_candidates_counts_as_a_false_reject(fixture_artifact):
    """Book title matches nothing in the fixture corpus, so blocking surfaces
    no candidates and `decide` returns `reject` ("no candidates") -- forced,
    not hoped for, exactly like the false-merge tests above. The label says
    `match`, so a `reject` decision here is a real false reject: a true match
    silently turned into what looks like a new, unrelated book."""
    case = EvalCase(
        case_id="forced_false_reject-no_candidates",
        stratum="no_candidates",
        book=EvalBook(book_id=9004, title="Zzzq Nothing Whatsoever Blocks To This Title"),
        candidates_shown=[],
        label=EvalLabel(
            verdict="match",
            work_key="OL999999999W",
            identity_rule="same_work",
            rationale="Constructed to force a false reject: nothing in the fixture "
            "corpus can possibly block to this title, so decide() rejects a case "
            "labelled as a real match.",
            labeled_at=datetime.date(2026, 9, 2),
            labeled_against_dump_date="2026-07-31",
        ),
    )
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        metrics, outcomes = run(con, fixture_artifact, [case], load_weights())
    outcome = outcomes[0]
    assert outcome.decision.verdict == "reject", (
        f"expected no candidates to block for a nonsense title; got "
        f"{outcome.decision.verdict!r} ({outcome.decision.reason})"
    )
    assert metrics.false_reject_rate == 1.0


def _prepared(case_id: str, verdict: str, *, candidates=(), volume_guards=()) -> PreparedCase:
    return PreparedCase(
        case_id=case_id,
        stratum="no_candidates",
        expected_work_key="OL1W" if verdict != "no_match" else None,
        expected_verdict=verdict,
        candidates=list(candidates),
        volume_guards_tripped=list(volume_guards),
        resolved={"OL1W": "OL1W"},
    )


def _middling_candidate() -> PreparedCandidate:
    """One candidate whose only present feature is a 0.65 title similarity:
    between the equal-weights reject (0.4) and accept (0.9) thresholds, so
    `decide` abstains on it."""
    return PreparedCandidate(
        work_key="OL1W",
        rules=["title_fp"],
        values={**dict.fromkeys(FEATURES), "title_similarity": 0.65, "popularity_prior": 0.0},
    )


def test_a_refused_search_abstains_and_is_not_a_false_reject():
    """R59: the false reject the labelled set actually contained
    (degenerate_title-014) was a `match` whose author shelf was over
    MAX_SHELF_SIZE -- zero candidates, but not because nothing was there.
    `evaluate` hands the prepared case's volume guards to `decide`, which
    abstains; and an abstention on a match is a review, not a false reject.

    The other two cases pin T27's deferred #10 around it: an abstained
    `match` (middling score) is not a false reject either, and an
    `ambiguous` case is excluded from the false-reject denominator -- only
    the one genuine `reject` on a `match` counts, over the three `match`
    cases, never over all four."""
    refused = _prepared("refused-shelf", "match", volume_guards=["author_shelf"])
    middling = _prepared("middling", "match", candidates=[_middling_candidate()])
    ambiguous_empty = _prepared("ambiguous-empty", "ambiguous")
    real_false_reject = _prepared("really-rejected", "match")

    metrics, outcomes = evaluate(
        [refused, middling, ambiguous_empty, real_false_reject], _equal_weights()
    )
    by_id = {o.case_id: o for o in outcomes}

    assert by_id["refused-shelf"].decision.verdict == "abstain"
    assert by_id["refused-shelf"].decision.reason == (
        "no candidates; search refused for volume: author_shelf"
    )
    assert by_id["refused-shelf"].false_merge is False
    assert by_id["refused-shelf"].correct is False

    assert by_id["middling"].decision.verdict == "abstain"
    assert by_id["ambiguous-empty"].decision.verdict == "reject"
    assert by_id["really-rejected"].decision.verdict == "reject"

    # 1 reject among the 3 `match` cases; the ambiguous reject is not in
    # either the numerator or the denominator.
    assert metrics.false_reject_rate == pytest.approx(1 / 3)
    assert metrics.abstention_rate == pytest.approx(2 / 4)


def test_a_refused_search_on_a_no_match_case_is_not_a_correct_no_match():
    """The other side of R59: abstaining on a `no_match` whose shelf was too
    big is honest but not correct -- `correct_no_match_rate` only counts
    `reject`. This is the cost the ruling accepted (+2 abstains) and it must
    show in the metric, not be hidden as a correct answer."""
    refused = _prepared("refused-no-match", "no_match", volume_guards=["author_shelf"])
    plain = _prepared("plain-no-match", "no_match")

    metrics, outcomes = evaluate([refused, plain], _equal_weights())
    by_id = {o.case_id: o for o in outcomes}

    assert by_id["refused-no-match"].decision.verdict == "abstain"
    assert by_id["refused-no-match"].correct is False
    assert by_id["plain-no-match"].decision.verdict == "reject"
    assert by_id["plain-no-match"].correct is True
    assert metrics.correct_no_match_rate == pytest.approx(0.5)


def test_prepare_records_the_volume_guards_blocking_tripped(fixture_artifact):
    """The corpus's 51-work "Selected Poems" block is a frequency-suppressed
    title (a volume guard, R59); a nonsense title trips nothing."""
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        (common_title,) = con.execute(
            f"""
            SELECT title FROM '{fixture_artifact.table("works")}'
            WHERE title_fp_freq > 50 ORDER BY work_key LIMIT 1
            """
        ).fetchone()
        prepared = prepare(
            con,
            fixture_artifact,
            [
                EvalCase(
                    case_id="common-001",
                    stratum="high_frequency_title",
                    book=EvalBook(book_id=1, title=common_title),
                    candidates_shown=[],
                    label=EvalLabel(
                        verdict="no_match",
                        work_key=None,
                        identity_rule="not_in_open_library",
                        rationale="Constructed: a frequency-suppressed title.",
                        labeled_at=datetime.date(2026, 9, 2),
                        labeled_against_dump_date="2026-07-31",
                    ),
                ),
                EvalCase(
                    case_id="nonsense-001",
                    stratum="no_candidates",
                    book=EvalBook(book_id=2, title="Zzzq Nothing Whatsoever Blocks To This Title"),
                    candidates_shown=[],
                    label=EvalLabel(
                        verdict="no_match",
                        work_key=None,
                        identity_rule="not_in_open_library",
                        rationale="Constructed: nothing blocks.",
                        labeled_at=datetime.date(2026, 9, 2),
                        labeled_against_dump_date="2026-07-31",
                    ),
                ),
            ],
        )
    by_id = {p.case_id: p for p in prepared}
    assert by_id["common-001"].volume_guards_tripped == ["title_fp"]
    assert by_id["common-001"].candidates == []
    assert by_id["nonsense-001"].volume_guards_tripped == []


def _artifact(tmp_path, dump_date: str = "2026-07-31", built_at: str | None = None):
    """A version directory with (optionally) a manifest carrying `built_at`,
    the shape `artifact_built_at` reads."""
    paths = ArtifactPaths(root=tmp_path, dump_date=dump_date)
    paths.ensure()
    if built_at:
        paths.manifest_path.write_text(json.dumps({"dump_date": dump_date, "built_at": built_at}))
    return paths


def test_prepared_cache_round_trips_through_a_file(tmp_path):
    prepared = [
        PreparedCase(
            case_id="c1",
            stratum="easy_baseline",
            expected_work_key="OL1W",
            expected_verdict="match",
            candidates=[
                PreparedCandidate(
                    work_key="OL1W",
                    rules=["title_fp"],
                    values={"title_similarity": 1.0, "year_agreement": None},
                ),
            ],
            resolved={"OL1W": "OL1W"},
        ),
        PreparedCase(
            case_id="c2",
            stratum="no_candidates",
            expected_work_key=None,
            expected_verdict="no_match",
            candidates=[],
            volume_guards_tripped=["author_shelf"],
            resolved={},
        ),
    ]
    paths = _artifact(tmp_path, built_at="2026-09-03T06:21:00+00:00")
    path = tmp_path / "cache.json"
    write_prepared_cache(path, paths, prepared)

    loaded = read_prepared_cache(path, paths, n_cases=2)

    assert loaded is not None
    assert [p.model_dump() for p in loaded] == [p.model_dump() for p in prepared]
    # None values must survive the JSON round trip, not turn into 0.0 or vanish.
    assert loaded[0].candidates[0].values["year_agreement"] is None
    # R59's field must survive too -- it decides abstain vs reject downstream.
    assert loaded[1].volume_guards_tripped == ["author_shelf"]

    header = json.loads(path.read_text())
    assert header["artifact_built_at"] == "2026-09-03T06:21:00+00:00"
    assert header["code_sha256"] == harness.code_sha256()


def test_prepared_cache_header_mismatch_returns_none(tmp_path):
    paths = _artifact(tmp_path)
    path = tmp_path / "cache.json"
    write_prepared_cache(path, paths, [])

    other_date = ArtifactPaths(root=tmp_path, dump_date="2026-08-31")
    assert read_prepared_cache(path, other_date, n_cases=0) is None  # dump_date differs
    assert read_prepared_cache(path, paths, n_cases=5) is None  # n_cases differs
    assert read_prepared_cache(tmp_path / "missing.json", paths, n_cases=0) is None
    # The control: the same artifact, the same count, the same code -> loads.
    assert read_prepared_cache(path, paths, n_cases=0) == []


def test_a_rebuilt_artifact_invalidates_the_prepared_cache(tmp_path):
    """R60: a same-date rebuild leaves dump_date, matcher_version and n_cases
    all unchanged -- the first header would have served the OLD artifact's
    candidates as the new artifact's evaluation. The manifest's `built_at`
    is what moves."""
    paths = _artifact(tmp_path, built_at="2026-09-03T06:21:00+00:00")
    path = tmp_path / "cache.json"
    write_prepared_cache(path, paths, [])
    assert read_prepared_cache(path, paths, n_cases=0) == []

    paths.manifest_path.write_text(
        json.dumps({"dump_date": paths.dump_date, "built_at": "2026-10-01T00:00:00+00:00"})
    )
    assert read_prepared_cache(path, paths, n_cases=0) is None


def test_a_code_change_to_a_fingerprinted_module_invalidates_the_prepared_cache(
    tmp_path, monkeypatch
):
    """R60: the header hashes the BYTES of the four modules whose code decides
    what `prepare` produces. Stand a scratch file in for them so the test can
    change one without editing the real source."""
    module = tmp_path / "blocking_stand_in.py"
    module.write_text("MAX_SHELF_SIZE = 500\n")
    monkeypatch.setattr(harness, "CODE_FINGERPRINT_FILES", (module,))

    paths = _artifact(tmp_path)
    path = tmp_path / "cache.json"
    write_prepared_cache(path, paths, [])
    assert read_prepared_cache(path, paths, n_cases=0) == []

    module.write_text("MAX_SHELF_SIZE = 1500\n")
    assert read_prepared_cache(path, paths, n_cases=0) is None


def test_code_sha256_covers_the_four_modules_that_shape_prepare():
    names = [p.name for p in harness.CODE_FINGERPRINT_FILES]
    assert names == ["blocking.py", "features.py", "normalize.py", "scoring.py"]
    assert all(p.exists() for p in harness.CODE_FINGERPRINT_FILES)
    assert len(harness.code_sha256()) == 64


def test_artifact_built_at_falls_back_to_the_build_report_then_none(tmp_path):
    paths = _artifact(tmp_path)
    assert harness.artifact_built_at(paths) is None
    paths.report_path.write_text(json.dumps({"built_at": "2026-09-03T06:21:00.384098+00:00"}))
    assert harness.artifact_built_at(paths) == "2026-09-03T06:21:00.384098+00:00"
    paths.manifest_path.write_text(json.dumps({"built_at": "2026-09-03T06:21:00.384484+00:00"}))
    assert harness.artifact_built_at(paths) == "2026-09-03T06:21:00.384484+00:00"


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
