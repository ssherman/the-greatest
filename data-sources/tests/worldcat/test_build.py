import json
from pathlib import Path

import pytest

from worldcat.pipeline.build import BuildFailed, build, source_fingerprint
from worldcat.pipeline.extract import ExtractIncomplete
from worldcat.pipeline.gates import Thresholds
from worldcat.pipeline.paths import TABLES, WorldcatPaths

LOOSE = Thresholds(min_records=1, max_records=10**9, min_redirects=1)


def test_a_build_produces_four_tables_a_report_and_a_passing_manifest(
    worldcat_artifact: WorldcatPaths,
):
    for table in TABLES:
        assert worldcat_artifact.table(table).exists(), table
    manifest = json.loads(worldcat_artifact.manifest_path.read_text())
    assert manifest["gates_passed"] is True
    assert manifest["dump_date"] == "2025-09-04"
    report = json.loads(worldcat_artifact.report_path.read_text())
    assert [g["name"] for g in report["gates"] if g["status"] == "fail"] == []
    assert not worldcat_artifact.staging_dir.exists()


def test_the_session_fixture_built_with_loose_thresholds_and_two_workers(
    worldcat_artifact: WorldcatPaths,
):
    report = json.loads(worldcat_artifact.report_path.read_text())
    assert report["extract"]["bad_frames"] == []
    assert "extract" in report["timings"] and "records" in report["timings"]
    assert report["timings"]["extract"]["rows"] == report["extract"]["kept"]


def test_a_failed_gate_raises_keeps_staging_and_marks_the_manifest(
    tmp_path: Path, worldcat_source: Path
):
    with pytest.raises(BuildFailed, match="gates"):
        build(
            source=worldcat_source,
            root=tmp_path,
            dump_date="2025-09-04",
            workers=1,
            memory_limit="1GB",
        )
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    assert json.loads(paths.manifest_path.read_text())["gates_passed"] is False
    assert paths.staging_dir.exists()


def test_catalogue_isbns_feed_the_coverage_gate(tmp_path: Path, worldcat_source: Path):
    ours = tmp_path / "ours.txt"
    ours.write_text("9780735211292\n9999999999999\n")
    with pytest.raises(BuildFailed):
        build(
            source=worldcat_source,
            root=tmp_path,
            dump_date="2025-09-04",
            workers=1,
            memory_limit="1GB",
            catalogue_isbns=ours,
            thresholds=LOOSE,
        )
    report_path = WorldcatPaths(root=tmp_path, dump_date="2025-09-04").report_path
    report = json.loads(report_path.read_text())
    gate = next(g for g in report["gates"] if g["name"] == "catalogue_coverage")
    assert gate["status"] == "fail" and gate["observed"]["resolved"] == 1


def test_source_fingerprint_changes_with_the_file(tmp_path: Path, worldcat_source: Path):
    a = source_fingerprint(worldcat_source)
    other = tmp_path / "other.zst"
    data = bytearray(worldcat_source.read_bytes())
    data[8] ^= 0xFF  # inside the first frame; the footer must stay intact to be readable
    other.write_bytes(bytes(data))
    assert a != source_fingerprint(other)
    assert len(a) == 64


def test_a_stray_shard_from_an_earlier_run_is_cleared_before_extracting(
    tmp_path: Path, worldcat_source: Path
):
    import duckdb

    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    stray = paths.staging_dir / "shard_099_00000.parquet"
    duckdb.connect().execute(f"COPY (SELECT 1 AS x) TO '{stray}' (FORMAT parquet)")
    (paths.staging_dir / "progress_099.txt").write_text("100.0% stale\n")

    build(
        source=worldcat_source,
        root=tmp_path,
        dump_date="2025-09-04",
        workers=1,
        memory_limit="1GB",
        thresholds=LOOSE,
        keep_staging=True,
    )

    assert not stray.exists()
    assert not (paths.staging_dir / "progress_099.txt").exists()


def test_resume_distills_the_shards_an_earlier_run_left(tmp_path: Path, worldcat_source: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    first = build(
        source=worldcat_source,
        root=tmp_path,
        dump_date="2025-09-04",
        workers=2,
        memory_limit="1GB",
        thresholds=LOOSE,
        keep_staging=True,
    )
    shards = sorted(p.name for p in paths.staging_dir.glob("shard_*.parquet"))
    for table in TABLES:
        paths.table(table).unlink()
    paths.manifest_path.unlink()

    second = build(
        source=worldcat_source,
        root=tmp_path,
        dump_date="2025-09-04",
        workers=2,
        memory_limit="1GB",
        thresholds=LOOSE,
        resume=True,
    )

    assert second["tables"] == first["tables"]
    assert second["extract"]["kept"] == first["extract"]["kept"] > 0
    assert "extract" not in second["timings"] and "records" in second["timings"]
    assert json.loads(paths.manifest_path.read_text())["gates_passed"] is True
    assert not paths.staging_dir.exists(), shards


def test_resume_without_a_finished_extraction_touches_nothing(
    tmp_path: Path, worldcat_source: Path
):
    import duckdb

    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    partial = paths.staging_dir / "shard_000_00000.parquet"
    duckdb.connect().execute(f"COPY (SELECT 1 AS x) TO '{partial}' (FORMAT parquet)")
    (paths.staging_dir / "progress_000.txt").write_text("40.0% lines=10 kept=5 bad=0 elapsed=3s\n")

    with pytest.raises(ExtractIncomplete, match="did not finish"):
        build(
            source=worldcat_source,
            root=tmp_path,
            dump_date="2025-09-04",
            memory_limit="1GB",
            thresholds=LOOSE,
            resume=True,
        )

    assert partial.exists() and not paths.manifest_path.exists()
