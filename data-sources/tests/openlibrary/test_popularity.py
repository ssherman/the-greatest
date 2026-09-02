import gzip

import pytest

from openlibrary.pipeline.derive import build_popularity
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import build_editions, stage_editions
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
    stage_editions(con, paths)
    build_editions(con, paths)
    (works_n_before,) = con.execute(f"SELECT count(*) FROM '{paths.table('works')}'").fetchone()
    rows = build_popularity(con, paths)
    yield con, paths, rows, works_n_before
    con.close()


def test_every_row_carries_at_least_one_signal(built):
    con, paths, _, _ = built
    (empty,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("popularity")}'
        WHERE edition_count = 0 AND readinglog_count = 0 AND ratings_count = 0
        """
    ).fetchone()
    assert empty == 0


def test_counts_are_never_null(built):
    con, paths, _, _ = built
    (nulls,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("popularity")}'
        WHERE edition_count IS NULL OR readinglog_count IS NULL OR ratings_count IS NULL
        """
    ).fetchone()
    assert nulls == 0


def test_average_rating_is_null_exactly_when_there_are_no_ratings(built):
    con, paths, _, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("popularity")}'
        WHERE (ratings_count = 0) <> (ratings_avg IS NULL)
        """
    ).fetchone()
    assert bad == 0


def test_average_rating_is_within_the_scale(built):
    con, paths, _, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("popularity")}'
        WHERE ratings_avg IS NOT NULL AND (ratings_avg < 1 OR ratings_avg > 5)
        """
    ).fetchone()
    assert bad == 0


def test_edition_count_matches_the_editions_table(built):
    con, paths, _, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM (
          SELECT e.work_key, count(*) AS actual, any_value(p.edition_count) AS stored
          FROM '{paths.table("editions")}' e
          JOIN '{paths.table("popularity")}' p USING (work_key)
          WHERE e.work_key IS NOT NULL
          GROUP BY e.work_key
        ) WHERE actual <> stored
        """
    ).fetchone()
    assert bad == 0


def test_popularity_does_not_prune_the_works_table(built):
    con, paths, _, works_n_before = built
    # popularity is a side table, derived from editions/ratings/reading-log, never
    # from `works` -- building it must never cause a row to disappear from `works`.
    #
    # Note this is deliberately NOT `pop_n <= works_n`: editions, ratings and
    # reading-log are independently-sampled dumps from `works` (see conftest's
    # `fixture_dumps`), so an edition's work_key is not guaranteed to resolve to a
    # row in the (separately sampled) `works` fixture -- in this corpus, editions
    # reference 56 distinct work_keys against only 34 rows in `works`. That is a
    # fixture-sampling artifact, not something `build_popularity` should paper
    # over by filtering against `works`: popularity is keyed by "any work_key with
    # a signal", not "any work_key currently present in `works`".
    (works_n_after,) = con.execute(f"SELECT count(*) FROM '{paths.table('works')}'").fetchone()
    assert works_n_after == works_n_before


def test_each_side_of_the_full_outer_join_contributes_rows_alone(tmp_path):
    # The fixture corpus (tests/fixtures/{editions,ratings,reading-log}.txt) has no
    # work that appears in ONLY ratings or ONLY reading-log -- every work_key those
    # two dumps reference also has at least one edition in tests/fixtures/editions.txt.
    # So the `built` fixture above cannot exercise the "editions_per_work has no
    # match" arm of the three-way FULL OUTER JOIN for those two sides. This test
    # builds a minimal, self-contained corpus with one work on each side alone and
    # checks all three directly, per the task brief's instruction to construct a
    # synthetic check when the fixtures don't cover it.
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    con = connect(paths, memory_limit="1GB")

    # editions.parquet, written directly -- build_popularity only ever reads its
    # `work_key` column, so there is no need to run the editions dump through
    # stage_editions/build_editions to get a usable table here.
    con.execute(
        f"""
        COPY (SELECT 'OL_EDITIONS_ONLYW' AS work_key)
        TO '{paths.table("editions")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    with gzip.open(paths.dump("ratings"), "wt") as f:
        f.write("/works/OL_RATINGS_ONLYW\t\\N\t4\t2020-01-01\n")
    with gzip.open(paths.dump("reading-log"), "wt") as f:
        f.write("/works/OL_LOG_ONLYW\t\\N\tWant to Read\t2020-01-01\n")

    rows = build_popularity(con, paths)
    assert rows == 3

    result = {
        row[0]: row[1:]
        for row in con.execute(
            f"""
            SELECT work_key, edition_count, readinglog_count, ratings_count, ratings_avg
            FROM '{paths.table("popularity")}'
            """
        ).fetchall()
    }

    # editions-only: no match on either the ratings or the reading-log side.
    assert result["OL_EDITIONS_ONLYW"] == (1, 0, 0, None)
    # ratings-only: no match on either the editions or the reading-log side.
    assert result["OL_RATINGS_ONLYW"] == (0, 0, 1, 4.0)
    # reading-log-only: no match on either the editions or the ratings side.
    assert result["OL_LOG_ONLYW"] == (0, 1, 0, None)

    con.close()


def test_ratings_that_fail_try_cast_do_not_count_or_skew_the_average(tmp_path):
    # tests/fixtures/ratings.txt carries only clean "1".."5" values -- the
    # TRY_CAST filter in `ratings_per_work` never actually trips against it. This
    # builds a corpus where it does: a work with a mix of valid and garbage rating
    # values, and a work whose ratings are garbage-only.
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    con = connect(paths, memory_limit="1GB")

    con.execute(
        f"""
        COPY (SELECT unnest(['OL_MIXEDW', 'OL_ALL_GARBAGEW']) AS work_key)
        TO '{paths.table("editions")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    with gzip.open(paths.dump("ratings"), "wt") as f:
        # OL_MIXEDW: two valid ratings (4, 2) and one garbage value -- ratings_count
        # and ratings_avg must reflect only the two valid rows (avg 3.0), not three.
        f.write("/works/OL_MIXEDW\t\\N\t4\t2020-01-01\n")
        f.write("/works/OL_MIXEDW\t\\N\t2\t2020-01-02\n")
        f.write("/works/OL_MIXEDW\t\\N\tnot-a-number\t2020-01-03\n")
        # OL_ALL_GARBAGEW: every rating row is unparseable.
        f.write("/works/OL_ALL_GARBAGEW\t\\N\tfive-stars\t2020-01-01\n")
        f.write("/works/OL_ALL_GARBAGEW\t\\N\t\\N\t2020-01-02\n")
    with gzip.open(paths.dump("reading-log"), "wt") as f:
        f.write("/works/OL_MIXEDW\t\\N\tWant to Read\t2020-01-01\n")

    build_popularity(con, paths)

    result = {
        row[0]: row[1:]
        for row in con.execute(
            f"""
            SELECT work_key, edition_count, readinglog_count, ratings_count, ratings_avg
            FROM '{paths.table("popularity")}'
            """
        ).fetchall()
    }

    assert result["OL_MIXEDW"] == (1, 1, 2, 3.0)
    # All-garbage ratings behave exactly like no ratings at all: ratings_count = 0
    # and ratings_avg IS NULL, never `ratings_count > 0` paired with a NULL average.
    assert result["OL_ALL_GARBAGEW"] == (1, 0, 0, None)

    con.close()
