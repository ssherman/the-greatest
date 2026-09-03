import pytest

from openlibrary.pipeline.derive import build_year_evidence
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
    rows = build_year_evidence(con, paths)
    yield con, paths, rows
    con.close()


def test_there_is_no_single_answer_column(built):
    con, paths, _ = built
    columns = {
        row[0]
        for row in con.execute(
            f"DESCRIBE SELECT * FROM '{paths.table('year_evidence')}'"
        ).fetchall()
    }
    # Collapsing to one year happens at the point of use, never in the pipeline.
    assert "first_publish_year" not in columns
    assert "publication_year" not in columns
    assert {
        "declared_year",
        "min_edition_year",
        "second_min_edition_year",
        "modal_edition_year",
    } <= columns


def test_second_minimum_is_at_least_the_minimum(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("year_evidence")}'
        WHERE second_min_edition_year IS NOT NULL
          AND second_min_edition_year < min_edition_year
        """
    ).fetchone()
    assert bad == 0


def test_second_minimum_is_null_when_only_one_edition_carries_a_year(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("year_evidence")}'
        WHERE edition_year_count = 1 AND second_min_edition_year IS NOT NULL
        """
    ).fetchone()
    assert bad == 0


def test_modal_year_count_never_exceeds_the_year_bearing_edition_count(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("year_evidence")}'
        WHERE modal_edition_year_count > edition_year_count
        """
    ).fetchone()
    assert bad == 0


def test_a_work_with_a_declared_year_and_no_editions_still_gets_a_row(built):
    con, paths, _ = built
    (rows,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("year_evidence")}'
        WHERE declared_year IS NOT NULL AND edition_count = 0
        """
    ).fetchone()
    assert rows >= 1, (
        "no work in the corpus has a declared year and no editions, so this "
        "test and the contradiction check below both assert nothing"
    )
    (contradiction,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("year_evidence")}'
        WHERE edition_count = 0 AND min_edition_year IS NOT NULL
        """
    ).fetchone()
    assert contradiction == 0


def test_no_row_has_neither_a_declared_year_nor_an_edition(built):
    con, paths, _ = built
    (useless,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("year_evidence")}'
        WHERE declared_year IS NULL AND edition_count = 0
        """
    ).fetchone()
    assert useless == 0
