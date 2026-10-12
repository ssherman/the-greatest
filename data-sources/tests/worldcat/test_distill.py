from pathlib import Path

import duckdb
import pytest

from worldcat.pipeline.distill import (
    PASS_ORDER,
    UnknownPass,
    build_holdings,
    build_isbns,
    build_records,
    build_redirects,
    unknown_passes,
)
from worldcat.pipeline.extract import extract_range
from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.seektable import read_seek_table


@pytest.fixture()
def built(tmp_path: Path, worldcat_source: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    n = len(read_seek_table(worldcat_source))
    extract_range(worldcat_source, paths, 0, 0, n, batch_size=20)
    con = duckdb.connect()
    con.execute("SET memory_limit='1GB'")
    assert unknown_passes(con, paths) == []
    counts = {
        "records": build_records(con, paths),
        "isbns": build_isbns(con, paths),
        "redirects": build_redirects(con, paths),
        "holdings": build_holdings(con, paths),
    }
    yield con, paths, counts
    con.close()


def _one(con, sql, params=()):
    return con.execute(sql, params).fetchone()


def test_pass_order_is_newest_first():
    assert PASS_ORDER[0] == "w2"
    assert PASS_ORDER[-1] == "worldcat_2022_09_titles_1_backup_2022_10_12"


def test_duplicate_passes_collapse_to_the_newest(built):
    con, paths, _ = built
    row = _one(
        con,
        f"SELECT genre, source_pass, source_type FROM '{paths.table('records')}' "
        "WHERE oclc = 1000415078",
    )
    assert row[0] == "Fiction"  # not the synthetic "STALE GENRE" from the older 2023_04_v3 pass
    assert row[1] in PASS_ORDER[:2]
    (n,) = _one(con, f"SELECT count(*) FROM '{paths.table('records')}' WHERE oclc = 1055766559")
    assert n == 1


def test_isbns_union_every_pass_of_a_number(built):
    con, paths, _ = built
    (isbns,) = _one(con, f"SELECT isbn13s FROM '{paths.table('records')}' WHERE oclc = 1055766559")
    # the brief pass carried the UK ISBN
    assert "9780735211292" in isbns and "9781847941831" in isbns
    assert _one(
        con, f"SELECT oclc FROM '{paths.table('isbns')}' WHERE isbn13 = '9781847941831'"
    ) == (1055766559,)


def test_non_book_and_isbn_less_records_are_absent(built):
    con, paths, _ = built
    for oclc in (123177986, 11280578):
        assert _one(
            con, f"SELECT count(*) FROM '{paths.table('records')}' WHERE oclc = ?", [oclc]
        ) == (0,)


def test_bad_checksum_isbn_is_kept_on_the_record_but_not_indexed(built):
    con, paths, _ = built
    (isbns,) = _one(con, f"SELECT isbn13s FROM '{paths.table('records')}' WHERE oclc = 9000000001")
    assert isbns == ["9780000000001"]
    assert _one(
        con, f"SELECT count(*) FROM '{paths.table('isbns')}' WHERE isbn13 = '9780000000001'"
    ) == (0,)


def test_an_isbn10_is_indexed_as_its_isbn13(built):
    con, paths, _ = built
    assert _one(
        con, f"SELECT oclc FROM '{paths.table('isbns')}' WHERE isbn13 = '9780395476901'"
    ) == (1000415078,)
    assert _one(
        con, f"SELECT count(*) FROM '{paths.table('isbns')}' WHERE length(isbn13) <> 13"
    ) == (0,)


def test_redirect_chains_collapse_and_cycles_are_flagged(built):
    con, paths, _ = built
    t = paths.table("redirects")
    assert _one(con, f"SELECT to_oclc, is_cycle FROM '{t}' WHERE from_oclc = 1003236695") == (
        37975719,
        False,
    )
    assert _one(con, f"SELECT to_oclc, is_cycle FROM '{t}' WHERE from_oclc = 9000000010") == (
        1055766559,
        False,
    )
    assert _one(con, f"SELECT is_cycle FROM '{t}' WHERE from_oclc = 9000000020") == (True,)


def test_holdings_take_the_latest_summary(built):
    con, paths, _ = built
    row = _one(
        con,
        f"SELECT total_holding_count, total_editions FROM '{paths.table('holdings')}' "
        "WHERE oclc = 1055766559",
    )
    assert row == (4000, 25)


def test_builders_return_row_counts_and_sort_by_key(built):
    con, paths, counts = built
    for name, n in counts.items():
        assert _one(con, f"SELECT count(*) FROM '{paths.table(name)}'") == (n,)
    key = {"records": "oclc", "isbns": "isbn13", "redirects": "from_oclc", "holdings": "oclc"}
    for name, column in key.items():
        (unsorted,) = _one(
            con,
            f"SELECT count(*) FROM (SELECT {column}, lag({column}) OVER () AS prev "
            f"FROM '{paths.table(name)}') WHERE prev > {column}",
        )
        assert unsorted == 0, name


def test_an_unknown_pass_prefix_is_refused(tmp_path: Path, worldcat_source: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    n = len(read_seek_table(worldcat_source))
    extract_range(worldcat_source, paths, 0, 0, n)
    con = duckdb.connect()
    con.execute(
        f"COPY (SELECT * REPLACE ('mystery_pass' AS pass) "
        f"FROM read_parquet('{paths.staging_dir}/shard_*.parquet') WHERE kind = 'record' LIMIT 1) "
        f"TO '{paths.shard(9, 0)}' (FORMAT parquet)"
    )
    assert unknown_passes(con, paths) == ["mystery_pass"]
    with pytest.raises(UnknownPass, match="mystery_pass"):
        build_records(con, paths)
