import pytest

from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.derive import build_popularity, build_work_authors, build_year_evidence
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import build_editions, stage_editions
from openlibrary.pipeline.gates import CANARY_WORK_KEYS, gates_passed, run_gates
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.redirects import build_redirects
from openlibrary.pipeline.works import build_works, stage_works


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


def test_the_evaluation_gate_is_declared_and_skipped_until_increment_2(built):
    con, paths = built
    results = run_gates(con, paths, previous_report=None)
    evaluation = next(r for r in results if r.name == "evaluation_set")
    assert evaluation.status == "skipped"


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
