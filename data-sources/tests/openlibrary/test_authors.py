import pytest

from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    staged = stage_authors(con, paths)
    counts = build_authors(con, paths)
    yield con, paths, staged, counts
    con.close()


def test_one_row_per_author(built):
    con, paths, staged, counts = built
    assert counts["authors"] == staged
    (distinct,) = con.execute(
        f"SELECT count(DISTINCT author_key) FROM '{paths.table('authors')}'"
    ).fetchone()
    assert distinct == staged


def test_author_names_explodes_primary_and_alternates(built):
    con, paths, _, counts = built
    # Every author contributes a primary row, so the exploded table is at least
    # as large as the author table, and larger when alternates exist.
    assert counts["author_names"] >= counts["authors"]
    (alternates,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('author_names')}' WHERE source = 'alternate'"
    ).fetchone()
    assert alternates > 0, "the fixture corpus has authors with alternate_names"


def test_every_author_name_row_carries_a_fingerprint(built):
    con, paths, _, _ = built
    (missing,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('author_names')}' WHERE name_fp IS NULL"
    ).fetchone()
    assert missing == 0


def test_messy_birth_dates_yield_a_year_or_null_never_a_wrong_year(built):
    con, paths, _, _ = built
    rows = con.execute(
        f"SELECT birth_year FROM '{paths.table('authors')}' WHERE birth_year IS NOT NULL"
    ).fetchall()
    for (year,) in rows:
        assert 1 <= year <= 2100, f"implausible birth_year {year}"


def test_an_author_with_no_name_still_gets_a_row_but_no_name_fp_row(built):
    con, paths, _, _ = built
    (nameless,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('authors')}' WHERE name IS NULL"
    ).fetchone()
    if nameless:
        (bad,) = con.execute(
            f"""
            SELECT count(*) FROM '{paths.table("author_names")}' an
            JOIN '{paths.table("authors")}' a USING (author_key)
            WHERE a.name IS NULL AND an.source = 'primary'
            """
        ).fetchone()
        assert bad == 0
