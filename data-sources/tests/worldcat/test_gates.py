from pathlib import Path

import duckdb
import pytest

from common.gates import GateResult
from worldcat.pipeline.distill import build_holdings, build_isbns, build_records, build_redirects
from worldcat.pipeline.extract import ExtractStats, extract_range
from worldcat.pipeline.gates import Thresholds, gates_passed, run_gates
from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.seektable import read_seek_table

LOOSE = Thresholds(min_records=1, max_records=10**9, min_redirects=1)


@pytest.fixture()
def built(tmp_path: Path, worldcat_source: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    stats = extract_range(worldcat_source, paths, 0, 0, len(read_seek_table(worldcat_source)))
    con = duckdb.connect()
    for builder in (build_records, build_isbns, build_redirects, build_holdings):
        builder(con, paths)
    yield con, paths, [stats]
    con.close()


def _by_name(results: list[GateResult]) -> dict[str, GateResult]:
    return {r.name: r for r in results}


def test_a_clean_build_passes_every_gate_and_skips_coverage_without_a_catalogue(built):
    con, paths, stats = built
    results = _by_name(
        run_gates(con, paths, extract_stats=stats, thresholds=LOOSE, catalogue_isbns=None)
    )
    assert [r.name for r in results.values() if r.status == "fail"] == []
    assert results["catalogue_coverage"].status == "skipped"
    assert results["canaries"].status == "pass"
    assert results["pass_prefixes"].status == "pass"
    assert results["bad_frames"].status == "pass"
    assert 0.9 < results["isbn_checksums"].observed["share_ok"] < 1.0  # the synthetic bad ISBN
    assert gates_passed(list(results.values()))


def test_production_floors_fail_a_tiny_build(built):
    con, paths, stats = built
    results = _by_name(
        run_gates(con, paths, extract_stats=stats, thresholds=Thresholds(), catalogue_isbns=None)
    )
    assert results["row_counts"].status == "fail"
    assert "records" in results["row_counts"].detail
    assert not gates_passed(list(results.values()))


def test_catalogue_coverage_measures_our_isbns(built, tmp_path: Path):
    con, paths, stats = built
    isbns = tmp_path / "ours.txt"
    isbns.write_text("9780735211292\n9780395476901\n9999999999999\n")
    results = _by_name(
        run_gates(con, paths, extract_stats=stats, thresholds=LOOSE, catalogue_isbns=isbns)
    )
    assert results["catalogue_coverage"].status == "fail"
    assert results["catalogue_coverage"].observed == {
        "isbns": 3,
        "resolved": 2,
        "share": pytest.approx(2 / 3),
    }
    results = _by_name(
        run_gates(
            con,
            paths,
            extract_stats=stats,
            thresholds=Thresholds(
                min_records=1,
                max_records=10**9,
                min_redirects=1,
                min_catalogue_coverage=0.5,
            ),
            catalogue_isbns=isbns,
        )
    )
    assert results["catalogue_coverage"].status == "pass"


def test_a_bad_frame_fails_the_build(built):
    con, paths, _ = built
    stats = [ExtractStats(worker=0, lines=1, kept=1, shards=1, bad_frames=[(7, "boom")])]
    results = _by_name(
        run_gates(con, paths, extract_stats=stats, thresholds=LOOSE, catalogue_isbns=None)
    )
    assert results["bad_frames"].status == "fail"
    assert results["bad_frames"].observed == {"bad_frames": [[7, "boom"]]}


def test_a_missing_canary_fails(built):
    con, paths, stats = built
    con.execute(
        f"COPY (SELECT * FROM '{paths.table('isbns')}' WHERE isbn13 <> '9780735211292') "
        f"TO '{paths.table('isbns')}' (FORMAT parquet)"
    )
    results = _by_name(
        run_gates(con, paths, extract_stats=stats, thresholds=LOOSE, catalogue_isbns=None)
    )
    assert results["canaries"].status == "fail"
    assert "9780735211292" in results["canaries"].detail
