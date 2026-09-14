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

# A metrics reading that clears every one of gates.threshold_failures's five
# bounds, mirroring the final calibration run -- see thresholds.json's
# `measured` block, which these numbers are copied from.
_PASSING_THRESHOLDS = {
    "min_candidate_recall_10": 0.90,
    "max_false_merge_rate": 0.03,
    "min_precision_at_accept": 0.95,
    "max_abstention_rate": 0.70,
    "min_correct_no_match_rate": 0.10,
}


def _metrics(**overrides) -> Metrics:
    base = dict(
        n_cases=448,
        n_accepted=100,
        n_no_match_cases=67,
        candidate_recall={5: 0.886, 10: 0.922, 50: 0.943},
        precision_at_accept=0.980,
        false_merge_rate=0.0201,
        false_reject_rate=0.0027,
        abstention_rate=0.643,
        correct_no_match_rate=0.134,
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


def test_threshold_failures_is_empty_when_every_metric_clears_its_bound():
    assert threshold_failures(_metrics(), _PASSING_THRESHOLDS) == []


def test_threshold_failures_names_each_metric_that_misses_its_bound():
    metrics = _metrics(false_merge_rate=0.05, abstention_rate=0.90)
    failures = threshold_failures(metrics, _PASSING_THRESHOLDS)
    assert len(failures) == 2
    assert any("false-merge" in f for f in failures)
    assert any("abstention" in f for f in failures)


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
