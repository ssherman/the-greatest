import json

import pytest

from common.normalize import NORMALIZER_VERSION
from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.derive import build_popularity, build_work_authors, build_year_evidence
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import build_editions, stage_editions
from openlibrary.pipeline.gates import run_gates
from openlibrary.pipeline.paths import TABLES, ArtifactPaths
from openlibrary.pipeline.redirects import build_redirects
from openlibrary.pipeline.report import (
    PIPELINE_VERSION,
    StageTimings,
    load_previous_report,
    write_build_report,
    write_manifest,
)
from openlibrary.pipeline.works import build_works, stage_works


@pytest.fixture()
def reported(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    timings = StageTimings()
    timings.record("works", 1.5, rows=10)
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
    gate_results = run_gates(con, paths, previous_report=None)
    report = write_build_report(
        con, paths, dump_date="2026-07-31", gate_results=gate_results, timings=timings
    )
    write_manifest(paths, dump_date="2026-07-31", gate_results=gate_results, timings=timings)
    yield con, paths, report
    con.close()


def test_report_is_written_to_the_version_directory(reported):
    _, paths, _ = reported
    assert paths.report_path.exists()
    assert paths.manifest_path.exists()


def test_report_records_every_table_with_rows_and_bytes(reported):
    _, _, report = reported
    for table in TABLES:
        assert table in report["tables"], table
        assert report["tables"][table]["rows"] >= 0
        assert report["tables"][table]["bytes"] > 0


def test_report_records_the_total_measured_size(reported):
    _, paths, report = reported
    expected = sum(paths.table(t).stat().st_size for t in TABLES)
    assert report["total_bytes"] == expected


def test_report_versions_the_normalizer_and_the_pipeline_separately(reported):
    _, _, report = reported
    # "Did the data change or did the code?" needs two answers, not one.
    assert report["normalizer_version"] == NORMALIZER_VERSION
    assert report["pipeline_version"] == PIPELINE_VERSION


def test_report_records_gate_results_and_timings(reported):
    _, _, report = reported
    names = {gate["name"] for gate in report["gates"]}
    assert {
        "row_counts",
        "field_coverage",
        "redirect_closure",
        "canary_lookups",
        "evaluation_set",
    } <= names
    assert report["timings"]["works"]["seconds"] == pytest.approx(1.5)


def test_report_is_valid_json_on_disk(reported):
    _, paths, report = reported
    assert json.loads(paths.report_path.read_text()) == report


def test_previous_report_lookup_finds_the_most_recent_earlier_build(tmp_path):
    for date in ("2026-05-31", "2026-06-30"):
        directory = tmp_path / "versions" / date
        directory.mkdir(parents=True)
        (directory / "build_report.json").write_text(json.dumps({"dump_date": date}))
    found = load_previous_report(tmp_path, before_dump_date="2026-07-31")
    assert found["dump_date"] == "2026-06-30"


def test_previous_report_lookup_returns_none_on_a_first_build(tmp_path):
    assert load_previous_report(tmp_path, before_dump_date="2026-07-31") is None
