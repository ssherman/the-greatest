import json

import pytest

from openlibrary.eval.harness import Metrics
from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.derive import build_popularity, build_work_authors, build_year_evidence
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import build_editions, stage_editions
from openlibrary.pipeline.gates import CANARY_WORK_KEYS, gates_passed, run_gates, threshold_failures
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.redirects import build_redirects
from openlibrary.pipeline.works import build_works, stage_works

# A metrics reading that clears every one of gates.threshold_failures's six
# bounds (R56), mirroring the reading 7 / R64 reading -- see thresholds.json,
# whose pinned bounds and `measured` block these numbers are copied from.
_PASSING_THRESHOLDS = {
    "min_candidate_recall_10": 0.90,
    "max_false_merge_rate": 0.015,
    "min_precision_at_accept": 0.98,
    "max_abstention_rate": 0.70,
    "min_correct_no_match_rate": 0.04,
    "max_false_reject_rate": 0.005,
}


def _metrics(**overrides) -> Metrics:
    base = dict(
        n_cases=448,
        n_accepted=146,
        n_no_match_cases=67,
        candidate_recall={5: 0.886, 10: 0.922, 50: 0.943},
        precision_at_accept=0.993,
        false_merge_rate=0.0068,
        false_reject_rate=0.0,
        abstention_rate=0.665,
        correct_no_match_rate=0.060,
    )
    base.update(overrides)
    return Metrics(**base)


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    stage_works(con, paths)
    build_works(con, paths)
    stage_authors(con, paths)
    build_authors(con, paths)
    stage_editions(con, paths)
    build_editions(con, paths)
    build_work_authors(con, paths)
    build_redirects(con, paths)
    build_year_evidence(con, paths)
    build_popularity(con, paths)
    yield con, paths
    con.close()


def test_canaries_are_the_spec_collision_works(built):
    # These four are the seeds of both the fixture corpus and the eval set's
    # hardest stratum; if they stop resolving, something structural broke.
    assert set(CANARY_WORK_KEYS) >= {"OL3809593W", "OL2014226W", "OL81205W", "OL8331643W"}


def test_a_clean_first_build_passes_every_gate(built):
    con, paths = built
    results = run_gates(con, paths, previous_report=None)
    failures = [r for r in results if r.status == "fail"]
    assert failures == [], failures
    assert gates_passed(results)


def test_the_evaluation_gate_reports_a_real_status_once_labels_exist(built):
    con, paths = built
    results = run_gates(con, paths, previous_report=None)
    evaluation = next(r for r in results if r.name == "evaluation_set")
    # The fixture corpus is a 683-line sample of the real dumps -- nearly all
    # 370 works the 448-case labeled set names are absent from it, so R50
    # makes "skipped" the honest, deterministic answer here. Against the real
    # 2026-07-31 artifact the same gate reports "pass" or "fail" instead (see
    # the report's real-artifact GateResult).
    assert evaluation.status == "skipped"
    assert "absent from this artifact" in evaluation.detail


# ---------------------------------------------------------------------------
# R60: the evaluation gate must be able to FAIL, and to pass, on the fixture
# artifact -- in seconds, with no prepared cache, against a labelled set whose
# works the artifact actually holds (`fixture_labelled_cases`, shared with the
# harness tests). `load_cases` and `THRESHOLDS_PATH` are looked up lazily
# inside `evaluation_gate`, so monkeypatching the module attributes is enough.
# ---------------------------------------------------------------------------

# Bounds that make a real claim about the fixture set independent of whatever
# weights.json currently holds: blocking reaches all ten labelled works by
# their unique titles, nothing is merged wrongly, no true match is rejected,
# the one negative is rejected. Precision and abstention depend on the
# calibrated weights, so they are left at their loosest.
_FIXTURE_THRESHOLDS = {
    "min_candidate_recall_10": 1.0,
    "max_false_merge_rate": 0.0,
    "min_precision_at_accept": 0.0,
    "max_abstention_rate": 1.0,
    "min_correct_no_match_rate": 1.0,
    "max_false_reject_rate": 0.0,
}


def _pin(monkeypatch, tmp_path, cases, thresholds: dict) -> None:
    monkeypatch.setattr("openlibrary.eval.dataset.load_cases", lambda: cases)
    thresholds_path = tmp_path / "thresholds.json"
    thresholds_path.write_text(json.dumps(thresholds))
    monkeypatch.setattr("openlibrary.eval.harness.THRESHOLDS_PATH", thresholds_path)


def test_the_evaluation_gate_passes_on_a_labelled_set_the_artifact_holds(
    built, monkeypatch, tmp_path, fixture_labelled_cases
):
    con, paths = built
    _pin(monkeypatch, tmp_path, fixture_labelled_cases, _FIXTURE_THRESHOLDS)

    results = run_gates(con, paths, previous_report=None)

    evaluation = next(r for r in results if r.name == "evaluation_set")
    assert evaluation.status == "pass", evaluation.detail
    assert "prepared fresh" in evaluation.detail  # R60: no cache was consulted
    assert evaluation.observed["n_cases"] == len(fixture_labelled_cases)
    assert evaluation.observed["candidate_recall"][10] == 1.0
    assert gates_passed(results)


def test_the_evaluation_gate_fails_when_recall_regresses(
    built, monkeypatch, tmp_path, fixture_labelled_cases
):
    """One case relabelled to a work the artifact does not hold: recall@10
    drops to 9/10 against a pinned floor of 1.0, and the gate must say so by
    name. (One unknown of ten labelled keeps R50's skip from firing -- that
    needs more than half absent.)"""
    con, paths = built
    cases = list(fixture_labelled_cases)
    cases[0] = cases[0].model_copy(
        update={"label": cases[0].label.model_copy(update={"work_key": "OL999999999W"})}
    )
    _pin(monkeypatch, tmp_path, cases, _FIXTURE_THRESHOLDS)

    results = run_gates(con, paths, previous_report=None)

    evaluation = next(r for r in results if r.name == "evaluation_set")
    assert evaluation.status == "fail"
    assert "recall@10 0.9000 < 1.0000" in evaluation.detail
    assert evaluation.observed["candidate_recall"][10] == 0.9
    assert not gates_passed(results)


def test_the_evaluation_gate_never_reads_a_prepared_cache_it_was_not_given(
    built, monkeypatch, tmp_path, fixture_labelled_cases
):
    """R60: a cache file at the conventional path under the artifact's tmp/
    -- written by an earlier CLI run, possibly against an earlier build --
    must not be picked up by `run_gates`. Plant one whose content would make
    the gate FAIL; the gate must prepare fresh and pass."""
    from openlibrary.eval.harness import PreparedCase, write_prepared_cache

    con, paths = built
    _pin(monkeypatch, tmp_path, fixture_labelled_cases, _FIXTURE_THRESHOLDS)
    poisoned = [
        PreparedCase(
            case_id=c.case_id,
            stratum=c.stratum,
            expected_work_key=c.label.work_key,
            expected_verdict=c.label.verdict,
            candidates=[],  # every labelled work "missed" -> recall 0
        )
        for c in fixture_labelled_cases
    ]
    write_prepared_cache(paths.tmp_dir / f"prepared-{paths.dump_date}.json", paths, poisoned)

    results = run_gates(con, paths, previous_report=None)

    evaluation = next(r for r in results if r.name == "evaluation_set")
    assert evaluation.status == "pass", evaluation.detail
    assert "prepared fresh" in evaluation.detail


def test_threshold_failures_is_empty_when_every_metric_clears_its_bound():
    assert threshold_failures(_metrics(), _PASSING_THRESHOLDS) == []


def test_threshold_failures_names_each_metric_that_misses_its_bound():
    metrics = _metrics(false_merge_rate=0.05, abstention_rate=0.90, false_reject_rate=0.05)
    failures = threshold_failures(metrics, _PASSING_THRESHOLDS)
    assert len(failures) == 3
    assert any("false-merge" in f for f in failures)
    assert any("abstention" in f for f in failures)
    assert any("false-reject" in f for f in failures)


def test_a_row_count_collapse_against_a_previous_build_fails(built):
    con, paths = built
    previous = {"tables": {"works": {"rows": 10_000_000}}}
    results = run_gates(con, paths, previous_report=previous)
    row_gate = next(r for r in results if r.name == "row_counts")
    assert row_gate.status == "fail"
    assert not gates_passed(results)


def _observed_coverage(con, paths, name: str) -> float:
    """What this build actually measured, so the tolerance tests do not depend
    on how many works the fixture corpus happens to contain."""
    first = run_gates(con, paths, previous_report=None)
    return next(r for r in first if r.name == "field_coverage").observed[name]


def test_a_coverage_collapse_against_a_previous_build_fails(built):
    """A previous build whose coverage was 25% higher is past
    MAX_COVERAGE_DROP -- the shape of a parser change that quietly stopped
    extracting a field."""
    con, paths = built
    observed = _observed_coverage(con, paths, "works.has_authors")
    previous = {"coverage": {"works.has_authors": observed / (1 - 0.25)}}

    results = run_gates(con, paths, previous_report=previous)

    coverage = next(r for r in results if r.name == "field_coverage")
    assert coverage.status == "fail"
    assert "works.has_authors" in coverage.detail
    assert not gates_passed(results)


def test_a_coverage_dip_within_tolerance_passes(built):
    """The control the failure test needs: without it the gate could be
    'fail whenever a previous report exists' and still look correct."""
    con, paths = built
    observed = _observed_coverage(con, paths, "works.has_authors")
    previous = {"coverage": {"works.has_authors": observed / (1 - 0.01)}}

    results = run_gates(con, paths, previous_report=previous)

    assert next(r for r in results if r.name == "field_coverage").status == "pass"


def test_a_missing_canary_fails(built, monkeypatch):
    con, paths = built
    monkeypatch.setattr("openlibrary.pipeline.gates.CANARY_WORK_KEYS", ("OL_DOES_NOT_EXIST_W",))
    results = run_gates(con, paths, previous_report=None)
    canary = next(r for r in results if r.name == "canary_lookups")
    assert canary.status == "fail"
