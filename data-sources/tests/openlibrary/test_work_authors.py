import pytest

from openlibrary.pipeline.derive import build_work_authors
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths
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
    pairs = build_work_authors(con, paths)
    yield con, paths, pairs
    con.close()


def test_pair_count_equals_the_sum_of_author_counts(built):
    con, paths, pairs = built
    (expected,) = con.execute(
        f"SELECT COALESCE(sum(author_count), 0) FROM '{paths.table('works')}'"
    ).fetchone()
    assert pairs == expected


def test_positions_are_dense_and_one_based(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM (
          SELECT work_key, min(position) AS lo, max(position) AS hi, count(*) AS n
          FROM '{paths.table("work_authors")}'
          GROUP BY work_key
        ) WHERE lo <> 1 OR hi <> n
        """
    ).fetchone()
    assert bad == 0


def test_no_null_author_keys_survive(built):
    con, paths, _ = built
    (nulls,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('work_authors')}' "
        "WHERE author_key IS NULL OR author_key = ''"
    ).fetchone()
    assert nulls == 0


def test_a_work_with_no_authors_contributes_no_rows(built):
    con, paths, _ = built
    (leaked,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("work_authors")}' wa
        JOIN '{paths.table("works")}' w USING (work_key)
        WHERE w.author_count = 0
        """
    ).fetchone()
    assert leaked == 0
