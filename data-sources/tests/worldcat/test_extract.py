import json
from pathlib import Path

import duckdb

from tests.fixtures.worldcat.seekable import write_seekable
from worldcat.pipeline.extract import SHARD_COLUMNS, extract_all, extract_range, keep, reduce
from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.seektable import read_seek_table

CORPUS = Path(__file__).parent.parent / "fixtures" / "worldcat" / "sample.jsonl"


def _rows():
    return [json.loads(line) for line in CORPUS.read_text(encoding="utf-8").splitlines()]


def _synthetic(tag: str) -> dict:
    return next(r for r in _rows() if r["metadata"].get("_synthetic") == tag)


def test_keep_wants_isbn_bearing_book_titles_redirects_and_holdings_summaries():
    assert keep(
        b'{"metadata":{"type":"title_json","record":{"generalFormat":"Book","isbns":["1"]}}}'
    )
    assert keep(
        b'{"metadata":{"type":"briefrecords_json","record":{"generalFormat":"Book","isbns":["1"]}}}'
    )
    assert keep(
        b'{"metadata":{"type":"redirect_title_json","record":{"redirected_oclc_number":5}}}'
    )
    assert keep(b'{"metadata":{"type":"search_holdings_summary_all_editions","record":{}}}')
    assert not keep(
        b'{"metadata":{"type":"title_json","record":{"generalFormat":"Book","isbns":[]}}}'
    )
    assert not keep(
        b'{"metadata":{"type":"title_json","record":{"generalFormat":"Music","isbns":["1"]}}}'
    )
    assert not keep(b'{"metadata":{"type":"not_found_title_json","record":{"not_found":1}}}')
    assert not keep(b'{"metadata":{"type":"legacysearch_html","html":"<td>"}}')


def test_reduce_flattens_a_title_record():
    row = next(
        r
        for r in _rows()
        if r["metadata"]["oclc_number"] == "0001055766559"
        and r["metadata"]["type"] == "title_json"
        and "_synthetic" not in r["metadata"]
    )
    out = reduce(row)
    assert set(out) == set(SHARD_COLUMNS)
    assert out["kind"] == "record"
    assert out["oclc"] == 1055766559
    assert out["type"] == "title_json"
    assert out["pass"] == "w2"
    assert out["title"].startswith("Atomic habits")
    assert out["year"] == 2018
    assert "9780735211292" in out["isbns_raw"]
    assert out["genre"] == "Nonfiction"
    assert "Habit" in out["subjects"]
    assert isinstance(out["merged_oclc"], list) and isinstance(out["other_format_oclc"], list)
    assert out["total_editions"] >= 16


def test_reduce_reads_dict_subjects_and_a_range_query_pass():
    out = reduce(_synthetic("dict_subjects"))
    assert out["subjects"] == ["Science fiction", "Robots"]
    assert out["pass"] == "range_query"
    assert out["pass_index"] is None


def test_reduce_flattens_a_redirect():
    # The corpus tags both links of the chain "chain"; the first row is chain1.
    out = reduce(_synthetic("chain"))
    assert (out["kind"], out["oclc"], out["redirect_to"]) == ("redirect", 9000000010, 9000000011)
    assert out["title"] is None and out["isbns_raw"] is None


def test_reduce_flattens_a_holdings_summary_with_its_pass_index():
    out = reduce(_synthetic("later_holdings"))
    assert (out["kind"], out["oclc"]) == ("holdings", 1055766559)
    assert (out["total_holding_count"], out["holdings_total_editions"]) == (4000, 25)
    assert out["pass_index"] == 99999999


def test_extract_range_carries_a_line_across_a_frame_boundary(tmp_path: Path):
    lines = CORPUS.read_bytes().splitlines()
    source = tmp_path / "s.zst"
    n = write_seekable(lines, source, frame_bytes=2048)
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()

    stats = extract_range(source, paths, 0, 0, n, batch_size=10)

    assert stats.lines == len(lines)
    assert stats.bad_frames == []
    expected = sum(1 for ln in lines if keep(ln))
    assert stats.kept == expected
    (count,) = (
        duckdb.connect()
        .execute(f"SELECT count(*) FROM read_parquet('{paths.staging_dir}/shard_*.parquet')")
        .fetchone()
    )
    assert count == expected
    assert stats.shards >= 2


def test_extract_all_splits_frames_across_workers_and_writes_progress(tmp_path: Path):
    lines = CORPUS.read_bytes().splitlines()
    source = tmp_path / "s.zst"
    write_seekable(lines, source, frame_bytes=4096)
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()

    stats = extract_all(source, paths, workers=2)

    assert sorted(s.worker for s in stats) == [0, 1]
    assert sum(s.lines for s in stats) == len(lines)
    assert (paths.staging_dir / "progress_000.txt").read_text().startswith("100.0%")


def test_a_corrupt_frame_is_counted_not_fatal(tmp_path: Path):
    lines = CORPUS.read_bytes().splitlines()
    source = tmp_path / "s.zst"
    n = write_seekable(lines, source, frame_bytes=4096)
    frames = read_seek_table(source)
    data = bytearray(source.read_bytes())
    f = frames[1]
    data[f.offset + 8 : f.offset + 24] = b"\x00" * 16
    source.write_bytes(bytes(data))
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()

    stats = extract_range(source, paths, 0, 0, n)

    assert [i for i, _ in stats.bad_frames] == [1]
    assert stats.lines > 0


def test_extract_all_counts_every_line_once_however_the_ranges_cut_it(tmp_path: Path):
    lines = CORPUS.read_bytes().splitlines()
    expected = sum(1 for ln in lines if keep(ln))
    # 300-byte frames put most lines across several frames, and several worker
    # boundaries inside a line; 4096 puts boundaries mid-line too.
    for frame_bytes, workers in [(300, 3), (300, 7), (4096, 3)]:
        root = tmp_path / f"{frame_bytes}_{workers}"
        source = root / "s.zst"
        source.parent.mkdir()
        write_seekable(lines, source, frame_bytes=frame_bytes)
        paths = WorldcatPaths(root=root, dump_date="2025-09-04")
        paths.ensure()

        stats = extract_all(source, paths, workers=workers)

        assert sum(s.lines for s in stats) == len(lines)
        assert sum(s.kept for s in stats) == expected
        con = duckdb.connect()
        (count,) = con.execute(
            f"SELECT count(*) FROM read_parquet('{paths.staging_dir}/shard_*.parquet')"
        ).fetchone()
        con.close()
        assert count == expected


def test_a_line_ending_exactly_on_a_frame_boundary_is_not_dropped(tmp_path: Path):
    lines = CORPUS.read_bytes().splitlines()
    source = tmp_path / "s.zst"
    write_seekable(lines, source, frame_lines=5)
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()

    stats = extract_all(source, paths, workers=3)

    assert sum(s.lines for s in stats) == len(lines)
