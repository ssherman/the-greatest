import json
from pathlib import Path

import duckdb

from common.gates import GateResult
from worldcat.pipeline.distill import build_holdings, build_isbns, build_records, build_redirects
from worldcat.pipeline.extract import extract_range
from worldcat.pipeline.paths import TABLES, WorldcatPaths
from worldcat.pipeline.report import (
    PIPELINE_VERSION,
    StageTimings,
    write_build_report,
    write_manifest,
)
from worldcat.pipeline.seektable import read_seek_table


def test_report_and_manifest_describe_the_build(tmp_path: Path, worldcat_source: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    stats = extract_range(worldcat_source, paths, 0, 0, len(read_seek_table(worldcat_source)))
    con = duckdb.connect()
    for builder in (build_records, build_isbns, build_redirects, build_holdings):
        builder(con, paths)
    timings = StageTimings()
    timings.record("extract", 1.5, rows=stats.kept)
    gates = [
        GateResult(name="row_counts", status="pass", detail="ok"),
        GateResult(name="x", status="skipped", detail="n/a"),
    ]

    report = write_build_report(
        con,
        paths,
        dump_date="2025-09-04",
        source_fingerprint="abc",
        gate_results=gates,
        timings=timings,
        extract=[stats],
    )
    manifest = write_manifest(
        paths,
        dump_date="2025-09-04",
        source_fingerprint="abc",
        gate_results=gates,
        timings=timings,
        tables=report["tables"],
    )

    assert set(report["tables"]) == set(TABLES)
    assert report["tables"]["records"]["rows"] > 0 and report["tables"]["records"]["bytes"] > 0
    assert report["extract"] == {"lines": stats.lines, "kept": stats.kept, "bad_frames": []}
    assert report["pipeline_version"] == PIPELINE_VERSION
    on_disk = json.loads(paths.manifest_path.read_text())
    assert on_disk == manifest
    assert manifest["gates_passed"] is True
    assert manifest["source_fingerprint"] == "abc"
    assert manifest["tables"]["isbns"] == report["tables"]["isbns"]["rows"]
    assert manifest["stages"] == ["extract"]


def test_a_failed_gate_marks_the_manifest(tmp_path: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    manifest = write_manifest(
        paths,
        dump_date="2025-09-04",
        source_fingerprint="abc",
        gate_results=[GateResult(name="row_counts", status="fail", detail="too few")],
        timings=StageTimings(),
        tables={},
    )
    assert manifest["gates_passed"] is False
