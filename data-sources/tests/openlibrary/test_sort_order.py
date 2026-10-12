import duckdb
import pytest

from openlibrary.pipeline.sort_order import SORT_KEYS, order_by, row_groups_in_order


def _write(path, rows, *, ordered: bool) -> None:
    con = duckdb.connect()
    con.execute("CREATE TABLE t (id_type VARCHAR, value VARCHAR)")
    con.executemany("INSERT INTO t VALUES (?, ?)", rows)
    order = "ORDER BY id_type, value" if ordered else "ORDER BY hash(value)"
    con.execute(f"COPY (SELECT * FROM t {order}) TO '{path}' (FORMAT parquet, ROW_GROUP_SIZE 2048)")
    con.close()


@pytest.fixture()
def rows():
    return [(t, f"{n:08d}") for t in ("goodreads", "isbn13") for n in range(10_000)]


def test_the_lookup_tables_have_sort_keys():
    assert SORT_KEYS == {
        "identifiers": ("id_type", "value"),
        "works": ("work_key",),
        "redirects": ("entity", "source_key"),
    }
    assert order_by("identifiers") == "id_type, value"


def test_a_sorted_file_reads_as_in_order(tmp_path, rows):
    path = tmp_path / "sorted.parquet"
    _write(path, rows, ordered=True)
    con = duckdb.connect()
    (groups,) = con.execute(
        f"SELECT count(DISTINCT row_group_id) FROM parquet_metadata('{path}')"
    ).fetchone()
    assert groups > 2, "the check needs several row groups to compare"
    assert row_groups_in_order(con, path, ("id_type", "value"))


def test_an_unsorted_file_is_caught(tmp_path, rows):
    path = tmp_path / "unsorted.parquet"
    _write(path, rows, ordered=False)
    assert not row_groups_in_order(duckdb.connect(), path, ("id_type", "value"))
